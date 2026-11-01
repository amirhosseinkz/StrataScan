import Foundation
import Testing
@testable import StrataCore

@Suite("Scan comparison work areas")
struct ScanComparisonWorkAreaTests {
    @Test("Baseline mesh extent becomes a finite work area in existing world coordinates")
    func derivesWorkAreaFromMesh() throws {
        let draftID = UUID()
        let scanID = UUID()
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: -2, y: 1, z: 4),
                Point3D(x: 3, y: 5, z: 9)
            ],
            normals: [],
            faces: []
        )

        let area = try ScanComparisonWorkArea.fromBaselineMesh(
            draftID: draftID,
            referenceScanID: scanID,
            snapshots: [snapshot]
        )

        #expect(area.draftID == draftID)
        #expect(area.referenceScanID == scanID)
        #expect(area.minimum == Point3D(x: -2, y: 1, z: 4))
        #expect(area.maximum == Point3D(x: 3, y: 5, z: 9))
    }

    @Test("Opposite mesh corners create a finite normalized work area")
    func derivesWorkAreaFromOppositeCorners() throws {
        let draftID = UUID()
        let scanID = UUID()

        let area = try ScanComparisonWorkArea.fromOppositeCorners(
            draftID: draftID,
            referenceScanID: scanID,
            first: Point3D(x: 4, y: -2, z: 3),
            second: Point3D(x: -1, y: 5, z: -4)
        )

        #expect(area.draftID == draftID)
        #expect(area.referenceScanID == scanID)
        #expect(area.minimum == Point3D(x: -1, y: -2, z: -4))
        #expect(area.maximum == Point3D(x: 4, y: 5, z: 3))
        #expect(throws: ScanComparisonWorkAreaError.degenerateGeometry) {
            try ScanComparisonWorkArea.fromOppositeCorners(
                draftID: draftID,
                referenceScanID: scanID,
                first: Point3D(x: 1, y: 1, z: 1),
                second: Point3D(x: 1, y: 2, z: 3)
            )
        }
    }

    @Test("Empty or flat mesh geometry cannot become a fabricated three-dimensional work area")
    func rejectsInsufficientMeshExtent() throws {
        #expect(throws: ScanComparisonWorkAreaError.emptyGeometry) {
            try ScanComparisonWorkArea.fromBaselineMesh(
                draftID: UUID(),
                referenceScanID: UUID(),
                snapshots: []
            )
        }
        let flatSnapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 1, z: 0)],
            normals: [],
            faces: []
        )
        #expect(throws: ScanComparisonWorkAreaError.degenerateGeometry) {
            try ScanComparisonWorkArea.fromBaselineMesh(
                draftID: UUID(),
                referenceScanID: UUID(),
                snapshots: [flatSnapshot]
            )
        }
    }

    @Test("Aligned comparison vertices must span the saved work area before coverage is supported")
    func evaluatesAlignedComparisonCoverage() throws {
        let baselineID = UUID()
        let comparisonID = UUID()
        let workArea = ScanComparisonWorkArea(
            draftID: UUID(),
            referenceScanID: baselineID,
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        var comparisonVertices: [Point3D] = []
        for x in 0...3 {
            for y in 0...3 {
                for z in 0...3 {
                    comparisonVertices.append(
                        Point3D(x: Float(x) / 3 - 2, y: Float(y) / 3, z: Float(z) / 3)
                    )
                }
            }
        }
        let comparisonMesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: comparisonVertices,
            normals: [],
            faces: []
        )
        let alignment = ScanAlignment(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetFromSource: .translation(x: 2, y: 0, z: 0),
            method: .landmarks
        )

        let report = try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
            workArea: workArea,
            alignment: alignment,
            comparisonSnapshots: [comparisonMesh]
        )

        #expect(report.status == ScanComparisonCoverageReport.Status.supported)
        #expect(report.inWorkAreaVertexCount == 64)
        #expect(report.axisSpanFractions == SIMD3<Float>(repeating: 1))
    }

    @Test("Sparse or wrongly targeted comparison geometry is never coverage support")
    func rejectsInsufficientOrMisalignedCoverage() throws {
        let baselineID = UUID()
        let comparisonID = UUID()
        let workArea = ScanComparisonWorkArea(
            draftID: UUID(),
            referenceScanID: baselineID,
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        let sparseMesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0.5, y: 0.5, z: 0.5)],
            normals: [],
            faces: []
        )
        let alignment = ScanAlignment(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetFromSource: .identity,
            method: .landmarks
        )

        let report = try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
            workArea: workArea,
            alignment: alignment,
            comparisonSnapshots: [sparseMesh]
        )
        #expect(report.status == ScanComparisonCoverageReport.Status.insufficient)
        #expect(throws: ScanComparisonCoverageError.workAreaDoesNotMatchAlignmentTarget) {
            try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
                workArea: workArea,
                alignment: ScanAlignment(
                    targetScanID: UUID(),
                    sourceScanID: comparisonID,
                    targetFromSource: .identity,
                    method: .landmarks
                ),
                comparisonSnapshots: [sparseMesh]
            )
        }
    }

    @Test("Comparison mesh inspection uses only observed triangles inside the work area")
    func clipsAndAlignsObservedMeshForInspection() throws {
        let area = ScanComparisonWorkArea(
            draftID: UUID(),
            referenceScanID: UUID(),
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: -2, y: 0, z: 0),
                Point3D(x: -1, y: 0, z: 0),
                Point3D(x: -2, y: 1, z: 0),
                Point3D(x: 3, y: 0, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2)), MeshFace(indices: (0, 2, 3))]
        )

        let clipped = try ScanComparisonWorkAreaMeshClipper().clip(
            snapshots: [snapshot],
            to: area,
            applying: .translation(x: 2, y: 0, z: 0)
        )

        #expect(clipped.count == 1)
        #expect(clipped[0].worldVertices == [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0)
        ])
        #expect(clipped[0].faces == [MeshFace(indices: (0, 1, 2))])
        #expect(clipped[0].normals.isEmpty)
    }

    @Test("Difference preview classifies only normal-consistent local correspondences")
    func previewsObservedSurfaceDifferences() throws {
        let area = ScanComparisonWorkArea(
            draftID: UUID(),
            referenceScanID: UUID(),
            minimum: Point3D(x: 0, y: 0, z: -0.2),
            maximum: Point3D(x: 1, y: 1, z: 0.2)
        )
        let baseline = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: Array(repeating: Point3D(x: 0, y: 0, z: 1), count: 3),
            faces: []
        )
        let comparison = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: -1, y: 0, z: 0.01),
                Point3D(x: 0, y: 0, z: 0.06),
                Point3D(x: -1, y: 1, z: -0.06),
                Point3D(x: 5, y: 5, z: 0)
            ],
            normals: [],
            faces: []
        )

        let preview = try ScanComparisonSurfaceDifferenceEvaluator().evaluate(
            baselineSnapshots: [baseline],
            comparisonSnapshots: [comparison],
            workArea: area,
            targetFromSource: .translation(x: 1, y: 0, z: 0)
        )

        #expect(preview.observations.map(\.classification) == [
            .coincident,
            .towardBaselineNormal,
            .againstBaselineNormal
        ])
        #expect(preview.unclassifiedComparisonVertexCount == 0)
    }

    @Test("Alignment quality gate requires spread, shape, and a low residual")
    func evaluatesAlignmentEvidenceQuality() throws {
        let baselineID = UUID()
        let comparisonID = UUID()
        let area = ScanComparisonWorkArea(
            draftID: UUID(),
            referenceScanID: baselineID,
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        let alignment = ScanAlignment(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetFromSource: .identity,
            method: .landmarks
        )
        let distributed = ScanAlignmentLandmarkSet(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetLandmarks: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            sourceLandmarks: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            rmsErrorMeters: 0.01
        )
        let clustered = ScanAlignmentLandmarkSet(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetLandmarks: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 0.1, y: 0, z: 0),
                Point3D(x: 0, y: 0.1, z: 0)
            ],
            sourceLandmarks: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 0.1, y: 0, z: 0),
                Point3D(x: 0, y: 0.1, z: 0)
            ],
            rmsErrorMeters: 0.01
        )
        let highResidual = ScanAlignmentLandmarkSet(
            targetScanID: baselineID,
            sourceScanID: comparisonID,
            targetLandmarks: distributed.targetLandmarks,
            sourceLandmarks: distributed.sourceLandmarks,
            rmsErrorMeters: 0.08
        )

        let evaluator = ScanComparisonAlignmentQualityEvaluator()
        #expect(try evaluator.evaluate(landmarks: distributed, alignment: alignment, workArea: area).status == .supported)
        #expect(try evaluator.evaluate(landmarks: clustered, alignment: alignment, workArea: area).status == .landmarkSpreadInsufficient)
        #expect(try evaluator.evaluate(landmarks: highResidual, alignment: alignment, workArea: area).status == .residualTooHigh)
    }
}
