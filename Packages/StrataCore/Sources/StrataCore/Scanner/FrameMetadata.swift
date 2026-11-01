import Foundation

public enum FrameTrackingState: String, Codable, CaseIterable, Equatable, Sendable {
    case notAvailable
    case limited
    case normal
}

public enum WorldMappingState: String, Codable, CaseIterable, Sendable {
    case notAvailable
    case limited
    case extending
    case mapped
}

/// Display orientation of the retained JPEG. Camera calibration and pose remain
/// in the native captured-image coordinate system for spatial projection.
public enum CapturedImageOrientation: String, Codable, CaseIterable, Equatable, Sendable {
    case up
    case right
    case down
    case left
}

/// Persisted pose/calibration information for a selected camera frame. When
/// `isTextureSourceCandidate` is true, the capture package also contains the
/// matching selected JPEG keyframe at the same capture cadence.
public struct FrameMetadata: Codable, Equatable, Sendable {
    public var timestamp: TimeInterval
    public var videoTimestamp: TimeInterval?
    public var imageWidth: Int
    public var imageHeight: Int
    public var intrinsics: CameraIntrinsics
    public var worldFromCamera: Transform4x4
    public var tracking: FrameTrackingState
    public var worldMapping: WorldMappingState
    public var isTextureSourceCandidate: Bool
    public var displayOrientation: CapturedImageOrientation?

    public init(
        timestamp: TimeInterval,
        videoTimestamp: TimeInterval?,
        imageWidth: Int,
        imageHeight: Int,
        intrinsics: CameraIntrinsics,
        worldFromCamera: Transform4x4,
        tracking: FrameTrackingState,
        worldMapping: WorldMappingState,
        isTextureSourceCandidate: Bool,
        displayOrientation: CapturedImageOrientation? = nil
    ) {
        self.timestamp = timestamp
        self.videoTimestamp = videoTimestamp
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.intrinsics = intrinsics
        self.worldFromCamera = worldFromCamera
        self.tracking = tracking
        self.worldMapping = worldMapping
        self.isTextureSourceCandidate = isTextureSourceCandidate
        self.displayOrientation = displayOrientation
    }
}

public enum FrameMetadataWriterError: Error, Equatable, Sendable {
    case alreadyFinished
    case ioFailure(String)
}

/// NDJSON keeps metadata append-only and independently recoverable if an
/// interrupted scan has a partial but valid prefix of frame records.
public actor FrameMetadataNDJSONWriter {
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init(destinationURL: URL, fileManager: FileManager = .default) throws {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: destinationURL, options: .atomic)
            handle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw FrameMetadataWriterError.ioFailure(error.localizedDescription)
        }
    }

    public func append(_ metadata: FrameMetadata) throws {
        guard let handle else { throw FrameMetadataWriterError.alreadyFinished }
        do {
            var line = try encoder.encode(metadata)
            line.append(0x0A)
            try handle.write(contentsOf: line)
        } catch let error as FrameMetadataWriterError {
            throw error
        } catch {
            throw FrameMetadataWriterError.ioFailure(error.localizedDescription)
        }
    }

    public func finish() throws {
        guard let handle else { throw FrameMetadataWriterError.alreadyFinished }
        do {
            try handle.synchronize()
            try handle.close()
            self.handle = nil
        } catch {
            throw FrameMetadataWriterError.ioFailure(error.localizedDescription)
        }
    }

    public func cancel() {
        try? handle?.close()
        handle = nil
    }
}
