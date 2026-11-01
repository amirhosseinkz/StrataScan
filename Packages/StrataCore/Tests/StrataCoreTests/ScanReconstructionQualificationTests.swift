import XCTest
@testable import StrataCore

final class ScanReconstructionQualificationTests: XCTestCase {
    func testQualifiedSurfaceEnablesAllInterchangeFormatsAndPreservesDepthFacts() throws {
        var telemetry = CaptureTelemetry()
        for timestamp in 1...3 {
            telemetry.record(.calibratedKeyframeCandidate(
                CalibratedKeyframeEvidence(
                    timestamp: TimeInterval(timestamp),
                    confidenceRatio: 0.8,
                    overlapRatio: 0.4,
                    newCoverageRatio: 0.2,
                    poseBaselineMeters: 0.3,
                    cadenceSeconds: 0.7
                )
            ))
            telemetry.record(.cameraMotion)
        }
        let bounds = try TSDFSurfaceBounds(
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        let validation = TSDFSurfaceValidationReport(
            failures: [],
            vertexCount: 3,
            triangleCount: 1,
            componentTriangleCounts: [1],
            bounds: bounds,
            robustBounds: bounds,
            duplicateBoundaryVertexCount: 0,
            boundarySeamMismatchCount: 0,
            sourceStatistics: TSDFReconstructionStatistics(
                processedFrameCount: 3,
                rejectedDepthSampleCount: 9,
                droppedVoxelUpdateCount: 2,
                rayLimitReachedFrameCount: 1
            ),
            statistics: TSDFSurfaceExtractionStatistics(processedSubmapCount: 1)
        )

        let report = ScanReconstructionQualificationReport(
            captureEvidence: telemetry.evidenceQualification,
            packageIntegrityIsValid: true,
            canonicalSpatialSourceAvailable: true,
            processedSurfaceAvailable: true,
            surfaceValidation: validation
        )

        XCTAssertTrue(report.isProcessedSurfaceEligible)
        XCTAssertTrue(report.exports.allSatisfy(\.isReady))
        XCTAssertEqual(report.reconstructionStatistics?.rejectedDepthSampleCount, 9)
        XCTAssertEqual(report.issues.map(\.code), [.rejectedDepthSamples, .droppedVoxelUpdates, .rayLimitReached])
    }

    func testMissingEvidenceAndSurfaceExplainWhichExportsAreBlocked() {
        let report = ScanReconstructionQualificationReport(
            captureEvidence: nil,
            packageIntegrityIsValid: true,
            canonicalSpatialSourceAvailable: true,
            processedSurfaceAvailable: false
        )

        XCTAssertFalse(report.isProcessedSurfaceEligible)
        XCTAssertEqual(report.issues.map(\.code), [.captureEvidenceUnavailable, .processedSurfaceUnavailable])
        XCTAssertTrue(report.exports.first(where: { $0.format == .ply })?.isReady == true)
        XCTAssertTrue(report.exports.first(where: { $0.format == .opf })?.isReady == true)
        XCTAssertEqual(
            report.exports.first(where: { $0.format == .glb })?.blockingIssueCodes,
            [.captureEvidenceUnavailable, .processedSurfaceUnavailable]
        )
    }
}
