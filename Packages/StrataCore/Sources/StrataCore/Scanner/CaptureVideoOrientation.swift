import CoreGraphics

/// The interface orientation fixed at the beginning of a raw ARKit recording.
/// ARKit camera buffers use a landscape-right sensor basis; the transform is
/// QuickTime display metadata and never changes the recorded pixels.
public enum CaptureVideoOrientation: String, CaseIterable, Sendable {
    case landscapeRight
    case portrait
    case landscapeLeft
    case portraitUpsideDown

    public func trackTransform(frameWidth: Int, frameHeight: Int) -> CGAffineTransform {
        let width = CGFloat(frameWidth)
        let height = CGFloat(frameHeight)

        return switch self {
        case .landscapeRight:
            .identity
        case .portrait:
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .landscapeLeft:
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .portraitUpsideDown:
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        }
    }
}
