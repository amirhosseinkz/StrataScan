import Foundation

/// A copied value packet emitted by a platform adapter. It intentionally holds
/// no `ARFrame`, `CVPixelBuffer`, or Metal buffer reference past the callback.
public struct CaptureFramePacket: Sendable {
    public var metadata: FrameMetadata
    public var depth: DepthFrameSample?
    public var featurePoints: [Point3D]
    /// A selected, complete calibrated RGB-depth-confidence source frame for
    /// lossless package replay. It is independent of optional JPEG encoding.
    public var calibratedKeyframe: CalibratedRGBDKeyframeSample?
    /// A bounded, JPEG-encoded camera keyframe selected by the capture adapter.
    /// It is copied data, never an ARFrame or CVPixelBuffer reference.
    public var textureSourceImageData: Data?
    /// The first successfully encoded keyframe may also provide this compact
    /// library preview. It is source imagery, not generated content.
    public var thumbnailImageData: Data?

    public init(
        metadata: FrameMetadata,
        depth: DepthFrameSample?,
        featurePoints: [Point3D],
        calibratedKeyframe: CalibratedRGBDKeyframeSample? = nil,
        textureSourceImageData: Data? = nil,
        thumbnailImageData: Data? = nil
    ) {
        self.metadata = metadata
        self.depth = depth
        self.featurePoints = featurePoints
        self.calibratedKeyframe = calibratedKeyframe
        self.textureSourceImageData = textureSourceImageData
        self.thumbnailImageData = thumbnailImageData
    }
}

public enum ScanCaptureEvent: Sendable {
    case frame(CaptureFramePacket)
    case mesh(MeshSnapshot)
    case meshRemoved([UUID])
    /// Complete latest-state registry captured while the AR session is still
    /// owned. This is authoritative for final raw-mesh persistence.
    case meshRegistrySnapshot([MeshSnapshot])
    case tracking(FrameTrackingState)
    case telemetry(CaptureTelemetryEvent)
    case interruptionBegan
    case interruptionEnded
    case failed(String)
    /// Sent after an adapter has stopped producing values. Consumers drain all
    /// preceding events before finalizing a capture package.
    case captureEnded
}
