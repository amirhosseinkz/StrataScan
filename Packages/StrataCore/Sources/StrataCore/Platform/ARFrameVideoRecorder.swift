#if os(iOS) && canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreVideo
import Foundation

public enum ARFrameVideoRecorderError: Error, Equatable, Sendable {
    case noFramesWritten
    case finalizationInProgress
    case writerStartFailed(String)
    case writerAppendFailed(String)
    case writerFinishFailed(String)
}

/// Records the AR camera frames already supplied by ARKit, avoiding a competing
/// AVCaptureSession. Audio is intentionally omitted to minimize scan privacy.
@MainActor
public final class ARFrameVideoRecorder {
    private let outputURL: URL
    private let orientation: CaptureVideoOrientation?
    private let fileManager: FileManager
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var captureStartTimestamp: TimeInterval?
    private var sourceTimestampOffset: TimeInterval = 0
    private var lastSourceTimestamp: TimeInterval?
    private var lastPresentationTimestamp: TimeInterval?
    private var isFinalizing = false

    public init(
        outputURL: URL,
        orientation: CaptureVideoOrientation? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.outputURL = outputURL
        self.orientation = orientation
        self.fileManager = fileManager
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }

    @discardableResult
    public func append(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> TimeInterval? {
        guard !isFinalizing else {
            throw ARFrameVideoRecorderError.finalizationInProgress
        }
        if writer == nil {
            try startWriter(for: pixelBuffer)
        }
        guard let writer, let input, let adaptor else {
            throw ARFrameVideoRecorderError.writerStartFailed("Writer was not initialized")
        }
        guard writer.status == .writing else {
            let message = writer.error?.localizedDescription ?? "Writer is not writing"
            cancel()
            throw ARFrameVideoRecorderError.writerAppendFailed(message)
        }

        guard timestamp.isFinite else {
            throw ARFrameVideoRecorderError.writerAppendFailed("AR frame timestamp is invalid")
        }
        let normalizedTimestamp = normalizedSourceTimestamp(timestamp)
        guard input.isReadyForMoreMediaData else {
            return nil
        }

        do {
            let startTimestamp = captureStartTimestamp ?? normalizedTimestamp
            var videoTimestamp = max(0, normalizedTimestamp - startTimestamp)
            if let lastPresentationTimestamp {
                videoTimestamp = max(videoTimestamp, lastPresentationTimestamp + minimumPresentationInterval)
            }
            let presentationTime = CMTime(seconds: videoTimestamp, preferredTimescale: 600)
            let writerOwnedBuffer = try makeWriterOwnedCopy(of: pixelBuffer, using: adaptor)
            let startsCapture = captureStartTimestamp == nil
            if startsCapture {
                writer.startSession(atSourceTime: .zero)
            }
            guard adaptor.append(writerOwnedBuffer, withPresentationTime: presentationTime) else {
                throw ARFrameVideoRecorderError.writerAppendFailed(writer.error?.localizedDescription ?? "Could not append AR frame")
            }
            if startsCapture {
                captureStartTimestamp = normalizedTimestamp
            }
            lastPresentationTimestamp = videoTimestamp
            return videoTimestamp
        } catch {
            // The writer cannot safely resume after a failed append. Releasing
            // it here also lets ARKit recycle the frame immediately.
            cancel()
            throw error
        }
    }

    public func finish() async throws -> URL {
        guard !isFinalizing else {
            throw ARFrameVideoRecorderError.finalizationInProgress
        }
        guard let writer, let input, captureStartTimestamp != nil else {
            cancel()
            throw ARFrameVideoRecorderError.noFramesWritten
        }
        guard writer.status == .writing else {
            let message = writer.error?.localizedDescription ?? "Writer is not writing"
            cancel()
            throw ARFrameVideoRecorderError.writerFinishFailed(message)
        }

        isFinalizing = true
        defer {
            isFinalizing = false
            releaseWriter()
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            removeOutputFile()
            throw ARFrameVideoRecorderError.writerFinishFailed(writer.error?.localizedDescription ?? "Writer did not complete")
        }
        return outputURL
    }

    /// Aborts any incomplete writer and removes its private partial output.
    /// This is safe while `finish()` is suspended: `cancelWriting()` wakes the
    /// finish completion and that continuation observes the cancelled status.
    public func cancel() {
        let activeWriter = writer
        releaseWriter()
        if let activeWriter {
            switch activeWriter.status {
            case .unknown, .writing:
                activeWriter.cancelWriting()
            case .completed, .failed, .cancelled:
                break
            @unknown default:
                break
            }
        }
        removeOutputFile()
    }

    private func startWriter(for pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
            )
            if let orientation {
                input.transform = orientation.trackTransform(frameWidth: width, frameHeight: height)
            }
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            guard writer.canAdd(input) else {
                writer.cancelWriting()
                throw ARFrameVideoRecorderError.writerStartFailed("Writer cannot add video input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                writer.cancelWriting()
                throw ARFrameVideoRecorderError.writerStartFailed(writer.error?.localizedDescription ?? "Could not start video writer")
            }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        } catch let error as ARFrameVideoRecorderError {
            removeOutputFile()
            throw error
        } catch {
            removeOutputFile()
            throw ARFrameVideoRecorderError.writerStartFailed(error.localizedDescription)
        }
    }

    private var minimumPresentationInterval: TimeInterval {
        1.0 / 600.0
    }

    private func normalizedSourceTimestamp(_ timestamp: TimeInterval) -> TimeInterval {
        if let lastSourceTimestamp, timestamp < lastSourceTimestamp {
            sourceTimestampOffset += lastSourceTimestamp - timestamp + minimumPresentationInterval
        }
        lastSourceTimestamp = timestamp
        return timestamp + sourceTimestampOffset
    }

    private func releaseWriter() {
        writer = nil
        input = nil
        adaptor = nil
        captureStartTimestamp = nil
        sourceTimestampOffset = 0
        lastSourceTimestamp = nil
        lastPresentationTimestamp = nil
    }

    private func removeOutputFile() {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            return
        }
        try? fileManager.removeItem(at: outputURL)
    }

    private func makeWriterOwnedCopy(
        of source: CVPixelBuffer,
        using adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw ARFrameVideoRecorderError.writerAppendFailed("Video buffer pool is unavailable")
        }

        var destination: CVPixelBuffer?
        let creationResult = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard creationResult == kCVReturnSuccess, let destination else {
            throw ARFrameVideoRecorderError.writerAppendFailed("Could not allocate a video buffer")
        }

        guard CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination),
              CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination),
              CVPixelBufferIsPlanar(source) == CVPixelBufferIsPlanar(destination)
        else {
            throw ARFrameVideoRecorderError.writerAppendFailed("Video buffer format changed during recording")
        }

        let sourceLockResult = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockResult == kCVReturnSuccess else {
            throw ARFrameVideoRecorderError.writerAppendFailed("Could not read an AR camera buffer")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let destinationLockResult = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockResult == kCVReturnSuccess else {
            throw ARFrameVideoRecorderError.writerAppendFailed("Could not prepare a video buffer")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        CVBufferPropagateAttachments(source, destination)
        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            guard planeCount == CVPixelBufferGetPlaneCount(destination) else {
                throw ARFrameVideoRecorderError.writerAppendFailed("Video buffer planes changed during recording")
            }
            for plane in 0..<planeCount {
                guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                else {
                    throw ARFrameVideoRecorderError.writerAppendFailed("Video buffer plane is unavailable")
                }
                copyRows(
                    from: sourceBaseAddress,
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: destinationBaseAddress,
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    rowCount: CVPixelBufferGetHeightOfPlane(source, plane)
                )
            }
        } else {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination)
            else {
                throw ARFrameVideoRecorderError.writerAppendFailed("Video buffer is unavailable")
            }
            copyRows(
                from: sourceBaseAddress,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                to: destinationBaseAddress,
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                rowCount: CVPixelBufferGetHeight(source)
            )
        }
        return destination
    }

    private func copyRows(
        from source: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        to destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        rowCount: Int
    ) {
        let byteCount = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0..<rowCount {
            destination.advanced(by: row * destinationBytesPerRow).copyMemory(
                from: source.advanced(by: row * sourceBytesPerRow),
                byteCount: byteCount
            )
        }
    }
}
#endif
