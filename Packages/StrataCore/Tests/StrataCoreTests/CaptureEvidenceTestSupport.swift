import Foundation
@testable import StrataCore

func authoritativeTestKeyframe(
    metadata: FrameMetadata,
    depth: DepthFrameSample,
    acceptanceReason: CalibratedKeyframeAcceptanceReason = .externalSourceSelection,
    exposure: CaptureExposureEvidence = .unavailable
) -> CalibratedRGBDKeyframeSample {
    let contract = CaptureEvidenceContract(
        source: .publicRGBDDataset,
        depthSource: .externalDepth,
        rgbSource: .externalColorResampledToDepthGrid,
        synchronization: .sourceTimestampMatched,
        timestamps: CaptureEvidenceTimestamps(
            capture: metadata.timestamp,
            cameraImage: metadata.timestamp,
            depth: depth.timestamp,
            confidence: depth.timestamp,
            pose: metadata.timestamp,
            maximumSourceDeltaSeconds: 0
        ),
        cameraImageWidth: metadata.imageWidth,
        cameraImageHeight: metadata.imageHeight,
        depthWidth: depth.width,
        depthHeight: depth.height,
        exposure: exposure,
        acceptanceEvidence: nil
    )
    return CalibratedRGBDKeyframeSample(
        metadata: metadata,
        depth: depth,
        acceptanceReason: acceptanceReason,
        evidence: nil,
        evidenceContract: contract
    )
}
