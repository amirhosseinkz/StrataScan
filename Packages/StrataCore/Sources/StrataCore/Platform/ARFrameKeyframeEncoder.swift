#if os(iOS) && canImport(ARKit)
@preconcurrency import ARKit
import CoreImage
import CoreVideo
import Foundation

/// A bounded luminance check for camera-frame admission. It is intentionally
/// not image analysis: no pixels leave the callback and no result is persisted.
enum ARFrameKeyframeQualityGate {
    struct Measurement {
        var rejectionReason: CalibratedKeyframeRejectionReason?
        var luminanceMean: Float?
        var luminanceVariance: Float?
        var adjacentDifference: Float?

        init(
            rejectionReason: CalibratedKeyframeRejectionReason?,
            luminanceMean: Float? = nil,
            luminanceVariance: Float? = nil,
            adjacentDifference: Float? = nil
        ) {
            self.rejectionReason = rejectionReason
            self.luminanceMean = luminanceMean
            self.luminanceVariance = luminanceVariance
            self.adjacentDifference = adjacentDifference
        }
    }

    static func admits(_ pixelBuffer: CVPixelBuffer) -> Bool {
        rejectionReason(for: pixelBuffer) == nil
    }

    static func rejectionReason(for pixelBuffer: CVPixelBuffer) -> CalibratedKeyframeRejectionReason? {
        measurement(for: pixelBuffer).rejectionReason
    }

    static func measurement(for pixelBuffer: CVPixelBuffer) -> Measurement {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return Measurement(rejectionReason: .blur)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return Measurement(rejectionReason: .blur) }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let sampleWidth = min(width, 32)
        let sampleHeight = min(height, 24)
        let stepX = max(1, width / sampleWidth)
        let stepY = max(1, height / sampleHeight)
        var values: [Float] = []
        values.reserveCapacity(sampleWidth * sampleHeight)

        if planeCount > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for y in stride(from: 0, to: height, by: stepY) {
                for x in stride(from: 0, to: width, by: stepX) {
                    values.append(Float(base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)) / 255)
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in stride(from: 0, to: height, by: stepY) {
                for x in stride(from: 0, to: width, by: stepX) {
                    let offset = y * bytesPerRow + x * 4
                    let blue = Float(base.load(fromByteOffset: offset, as: UInt8.self)) / 255
                    let green = Float(base.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255
                    let red = Float(base.load(fromByteOffset: offset + 2, as: UInt8.self)) / 255
                    values.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
                }
            }
        }
        guard !values.isEmpty else { return Measurement(rejectionReason: .blur) }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        let adjacentDifference = zip(values, values.dropFirst()).reduce(Float.zero) {
            $0 + abs($1.0 - $1.1)
        } / Float(max(1, values.count - 1))
        let rejection: CalibratedKeyframeRejectionReason? = if mean < 0.08 || mean > 0.94 {
            .exposure
        } else if sqrt(variance) < 0.025 || adjacentDifference < 0.012 {
            .blur
        } else {
            nil
        }
        return Measurement(
            rejectionReason: rejection,
            luminanceMean: mean,
            luminanceVariance: variance,
            adjacentDifference: adjacentDifference
        )
    }
}

/// Encodes a deliberately small number of copied AR camera frames outside of
/// ARKit's frame-delivery callback. The pixel buffer is copied before queueing,
/// so no `ARFrame` or ARKit-owned image is retained after the callback returns.
@MainActor
final class ARFrameKeyframeEncoder {
    private static let maximumPendingEncodes = 1
    private let encodingQueue: OperationQueue
    private var pendingJobs: [UUID: BlockOperation] = [:]
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    init() {
        let queue = OperationQueue()
        queue.name = "com.stratascan.raw-keyframe-encoding"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        encodingQueue = queue
    }

    /// Returns false without copying the source when the bounded encoder is
    /// busy. Geometry capture must never queue behind retained imagery.
    func enqueue(
        sourcePixelBuffer: CVPixelBuffer,
        metadata: FrameMetadata,
        completion: @escaping @MainActor (FrameMetadata, Data?) -> Void
    ) -> Bool {
        guard pendingJobs.count < Self.maximumPendingEncodes,
              let copiedPixelBuffer = Self.copy(sourcePixelBuffer)
        else {
            return false
        }

        let jobID = UUID()
        let job = KeyframeEncodingJob(pixelBuffer: copiedPixelBuffer, metadata: metadata)
        let operation = BlockOperation { [weak self, job] in
            let jpegData = Self.jpegData(for: job)
            Task { @MainActor [weak self] in
                self?.complete(jobID: jobID, metadata: job.metadata, jpegData: jpegData, completion: completion)
            }
        }
        pendingJobs[jobID] = operation
        encodingQueue.addOperation(operation)
        return true
    }

    /// Waits until all accepted frames have either yielded copied JPEG data or
    /// failed encoding. Call only after pausing AR delivery and before emitting
    /// the capture terminal event, so the collector can drain those values.
    func drain() async {
        guard !pendingJobs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    /// Explicit discard/failure cleanup. Cancelled jobs never call their
    /// completion, which prevents stale imagery entering a later attempt.
    func cancel() {
        pendingJobs.values.forEach { $0.cancel() }
        pendingJobs.removeAll(keepingCapacity: false)
        resumeDrainContinuations()
    }

    private func complete(
        jobID: UUID,
        metadata: FrameMetadata,
        jpegData: Data?,
        completion: @escaping @MainActor (FrameMetadata, Data?) -> Void
    ) {
        guard pendingJobs.removeValue(forKey: jobID) != nil else { return }
        completion(metadata, jpegData)
        if pendingJobs.isEmpty {
            resumeDrainContinuations()
        }
    }

    private func resumeDrainContinuations() {
        let continuations = drainContinuations
        drainContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    nonisolated private static func jpegData(for job: KeyframeEncodingJob) -> Data? {
        let sourceImage = CIImage(cvPixelBuffer: job.pixelBuffer)
        let maximumDimension: CGFloat = 1_280
        let sourceExtent = sourceImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(sourceExtent.width, sourceExtent.height))
        let image = scale < 1
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : sourceImage
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }

    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes,
            &destination
        ) == kCVReturnSuccess,
        let destination
        else {
            return nil
        }

        guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(destination) else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess
        else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination)
            else {
                return nil
            }
            memcpy(
                destinationBaseAddress,
                sourceBaseAddress,
                min(CVPixelBufferGetDataSize(source), CVPixelBufferGetDataSize(destination))
            )
            return destination
        }

        for plane in 0..<planeCount {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else {
                return nil
            }
            let bytesPerRow = min(
                CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            )
            let rowCount = min(
                CVPixelBufferGetHeightOfPlane(source, plane),
                CVPixelBufferGetHeightOfPlane(destination, plane)
            )
            for row in 0..<rowCount {
                memcpy(
                    destinationBaseAddress.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(destination, plane)),
                    sourceBaseAddress.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(source, plane)),
                    bytesPerRow
                )
            }
        }
        return destination
    }
}

/// `CVPixelBuffer` is CoreVideo reference storage, not a Swift Sendable value.
/// This wrapper is safe because `ARFrameKeyframeEncoder.copy(_:)` creates an
/// exclusive owned copy and the job is read only by one serial operation.
private final class KeyframeEncodingJob: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let metadata: FrameMetadata

    init(pixelBuffer: CVPixelBuffer, metadata: FrameMetadata) {
        self.pixelBuffer = pixelBuffer
        self.metadata = metadata
    }
}
#endif
