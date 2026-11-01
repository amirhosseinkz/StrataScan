import Foundation
import Testing
@testable import StrataCore

@Suite("RGB-D point cloud fusion")
struct RGBDPointCloudFusionTests {
    @Test("Fuses AR-world samples in one voxel and averages only observed RGB")
    func fusesSamplesWithoutInventingColor() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.1,
            maximumVoxelCount: 4,
            maximumSamplesPerBatch: 4,
            maximumSamplesPerVoxel: 3
        )
        var fusion = RGBDPointCloudFusion(configuration: configuration)

        let result = fusion.append([
            RGBDPointSample(
                position: Point3D(x: 0.01, y: 0.02, z: 0.03),
                confidence: 1,
                color: PointCloudColor(red: 30, green: 60, blue: 90)
            ),
            RGBDPointSample(
                position: Point3D(x: 0.03, y: 0.03, z: 0.04),
                confidence: 2,
                color: nil
            ),
            RGBDPointSample(
                position: Point3D(x: 0.05, y: 0.04, z: 0.03),
                confidence: 1,
                color: PointCloudColor(red: 90, green: 30, blue: 150)
            )
        ])

        #expect(result.acceptedSampleCount == 3)
        #expect(result.createdVoxelCount == 1)
        #expect(result.updatedVoxelCount == 2)

        let fusedPoints = fusion.fusedPoints()
        #expect(fusedPoints.count == 1)
        let point = try #require(fusedPoints.first)
        #expect(point.position.isApproximatelyEqual(to: Point3D(x: 0.03, y: 0.03, z: 0.033_333_335)))
        #expect(point.confidence == 2)
        #expect(point.sampleCount == 3)
        #expect(point.coloredSampleCount == 2)
        #expect(point.color == PointCloudColor(red: 60, green: 45, blue: 120))
        #expect(fusion.coloredPoints() == [
            ColoredPointCloudPoint(
                position: point.position,
                confidence: 2,
                color: PointCloudColor(red: 60, green: 45, blue: 120)
            )
        ])
    }

    @Test("Hard batch, voxel, and per-voxel limits reject excess input predictably")
    func enforcesBounds() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.1,
            maximumVoxelCount: 1,
            maximumSamplesPerBatch: 3,
            maximumSamplesPerVoxel: 1
        )
        var fusion = RGBDPointCloudFusion(configuration: configuration)

        let result = fusion.append([
            RGBDPointSample(position: Point3D(x: 0.01, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 0.21, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 0.02, y: 0, z: 0), confidence: 2),
            RGBDPointSample(position: Point3D(x: 0.03, y: 0, z: 0), confidence: 2)
        ])

        #expect(result.acceptedSampleCount == 1)
        #expect(result.createdVoxelCount == 1)
        #expect(result.rejectedByVoxelLimitCount == 1)
        #expect(result.rejectedByVoxelSampleLimitCount == 1)
        #expect(result.rejectedByBatchLimitCount == 1)
        #expect(fusion.voxelCount == 1)
        #expect(fusion.fusedPoints().first?.sampleCount == 1)
    }

    @Test("Nonfinite and nonrepresentable grid positions do not enter fusion")
    func rejectsUnsafeCoordinates() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.01,
            maximumVoxelCount: 2,
            maximumSamplesPerBatch: 3,
            maximumSamplesPerVoxel: 2
        )
        var fusion = RGBDPointCloudFusion(configuration: configuration)

        let result = fusion.append([
            RGBDPointSample(position: Point3D(x: .nan, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: .greatestFiniteMagnitude, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 0, y: 0, z: 0), confidence: 1)
        ])

        #expect(result.acceptedSampleCount == 1)
        #expect(result.rejectedInvalidSampleCount == 2)
        #expect(fusion.voxelCount == 1)
    }

    @Test("Rejects a conflicting depth return before it blurs a voxel surface or its observed RGB")
    func rejectsInternallyInconsistentSamples() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.1,
            maximumVoxelCount: 4,
            maximumSamplesPerBatch: 4,
            maximumSamplesPerVoxel: 4
        )
        var fusion = RGBDPointCloudFusion(configuration: configuration)

        let result = fusion.append([
            RGBDPointSample(
                position: Point3D(x: 0.02, y: 0.02, z: 0.02),
                confidence: 1,
                color: PointCloudColor(red: 20, green: 40, blue: 60)
            ),
            RGBDPointSample(
                position: Point3D(x: 0.04, y: 0.02, z: 0.02),
                confidence: 2,
                color: PointCloudColor(red: 40, green: 60, blue: 80)
            ),
            RGBDPointSample(
                position: Point3D(x: 0.095, y: 0.095, z: 0.095),
                confidence: 2,
                color: PointCloudColor(red: 255, green: 255, blue: 255)
            )
        ])

        #expect(result.acceptedSampleCount == 2)
        #expect(result.rejectedInconsistentSampleCount == 1)

        let point = try #require(fusion.fusedPoints().first)
        #expect(point.position.isApproximatelyEqual(to: Point3D(x: 0.03, y: 0.02, z: 0.02)))
        #expect(point.sampleCount == 2)
        #expect(point.color == PointCloudColor(red: 30, green: 50, blue: 70))
    }

    @Test("Keeps a standalone depth return so valid thin surfaces need no artificial consensus")
    func keepsStandaloneDepthReturn() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.1,
            maximumVoxelCount: 4,
            maximumSamplesPerBatch: 4,
            maximumSamplesPerVoxel: 4
        )
        var fusion = RGBDPointCloudFusion(configuration: configuration)
        let sample = RGBDPointSample(
            position: Point3D(x: 0.095, y: 0.095, z: 0.095),
            confidence: 1,
            color: nil
        )

        let result = fusion.append([sample])

        #expect(result.acceptedSampleCount == 1)
        #expect(result.rejectedInconsistentSampleCount == 0)
        #expect(fusion.fusedPoints() == [
            FusedRGBDPoint(
                position: sample.position,
                confidence: 1,
                color: nil,
                sampleCount: 1,
                coloredSampleCount: 0
            )
        ])
    }

    @Test("Equivalent bounded append batches produce the same fused result")
    func producesStableResultAcrossBatchBoundaries() throws {
        let configuration = try RGBDPointCloudFusionConfiguration(
            voxelSizeMeters: 0.1,
            maximumVoxelCount: 4,
            maximumSamplesPerBatch: 4,
            maximumSamplesPerVoxel: 4
        )
        let samples = [
            RGBDPointSample(position: Point3D(x: 0.02, y: 0.02, z: 0.02), confidence: 1),
            RGBDPointSample(position: Point3D(x: 0.04, y: 0.02, z: 0.02), confidence: 2),
            RGBDPointSample(position: Point3D(x: 0.03, y: 0.03, z: 0.02), confidence: 2)
        ]

        var singleBatch = RGBDPointCloudFusion(configuration: configuration)
        _ = singleBatch.append(samples)

        var splitBatches = RGBDPointCloudFusion(configuration: configuration)
        _ = splitBatches.append(Array(samples.prefix(1)))
        _ = splitBatches.append(Array(samples.dropFirst()))

        #expect(singleBatch.fusedPoints() == splitBatches.fusedPoints())
    }

    @Test("Configuration rejects resource limits outside the fixed safe range")
    func rejectsUnsafeConfiguration() {
        #expect(throws: RGBDPointCloudFusionError.invalidVoxelSizeMeters(0)) {
            _ = try RGBDPointCloudFusionConfiguration(voxelSizeMeters: 0)
        }
        #expect(throws: RGBDPointCloudFusionError.invalidMaximumVoxelCount(250_001)) {
            _ = try RGBDPointCloudFusionConfiguration(maximumVoxelCount: 250_001)
        }
        #expect(throws: RGBDPointCloudFusionError.invalidMaximumSamplesPerBatch(10_001)) {
            _ = try RGBDPointCloudFusionConfiguration(maximumSamplesPerBatch: 10_001)
        }
        #expect(throws: RGBDPointCloudFusionError.invalidMaximumSamplesPerVoxel(1_025)) {
            _ = try RGBDPointCloudFusionConfiguration(maximumSamplesPerVoxel: 1_025)
        }
    }
}
