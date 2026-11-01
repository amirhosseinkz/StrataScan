import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StrataCore

@Suite("Public RGB-D benchmark intake")
struct PublicRGBDBenchmarkIntakeTests {
    @Test("Normalizes official optical coordinates before production unprojection")
    func normalizesOpticalCameraBasis() throws {
        let worldFromOptical = Transform4x4.translation(x: 10, y: 20, z: 30)
        let normalized = try PublicRGBDBenchmarkIntake.normalizedWorldFromCamera(
            worldFromOptical,
            convention: .opticalPositiveXYZ
        )

        // The production unprojector emits negative XYZ. After explicit basis
        // normalization this must equal the official loader's optical +XYZ
        // point followed by the published camera-to-world pose.
        let actual = normalized.applying(to: Point3D(x: -0.4, y: -0.2, z: -2))
        #expect(actual.isApproximatelyEqual(to: Point3D(x: 10.4, y: 20.2, z: 32)))

        let legacy = try PublicRGBDBenchmarkIntake.normalizedWorldFromCamera(
            worldFromOptical,
            convention: .legacyStrataNegativeXYZ
        )
        #expect(legacy.applying(to: Point3D(x: -0.4, y: -0.2, z: -2))
            .isApproximatelyEqual(to: Point3D(x: 9.6, y: 19.8, z: 28)))
    }

    @Test("Imports a checksum-bound ARKitScenes fixture and reopens idempotently")
    func importsAndReopensIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifestURL = try fixture.makeManifest(includeReference: true)

        let first = try await PublicRGBDBenchmarkIntake().importDataset(
            manifestURL: manifestURL,
            sourceRoot: fixture.source,
            outputRoot: fixture.output
        )
        let second = try await PublicRGBDBenchmarkIntake().importDataset(
            manifestURL: manifestURL,
            sourceRoot: fixture.source,
            outputRoot: fixture.output
        )

        #expect(first.mutatedOutput)
        #expect(!second.mutatedOutput)
        #expect(first.evidenceLevel == "E2-input-ready")
        #expect(first.selectedFrameCount == 2)
        #expect(first.validDepthSampleCount == 7)
        #expect(first.canonicalSpatialRecordCount == 1)
        #expect(second.canonicalSpatialRecordCount == 1)
        #expect(first.sourceManifestSHA256 == second.sourceManifestSHA256)
        let store = try FileAssetStore(rootURL: fixture.output)
        #expect(try await store.validatePackage(id: fixture.scanID).isValid)
        let packageURL = try await store.packageURL(for: fixture.scanID)
        let manifest = try await store.loadManifest(id: fixture.scanID)
        let integrity = try await store.validatePackage(id: fixture.scanID)
        let canonical = try CanonicalSpatialChunkReader().open(
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
        #expect(canonical.recordCount == 1)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
        #expect(archive.records.allSatisfy { $0.acceptanceReason == .externalSourceSelection })
        #expect(archive.records.allSatisfy { $0.evidenceContract?.acceptanceEvidence == nil })
        let firstFrame = try archive.readKeyframe(at: 0)
        let firstPoint = firstFrame.depth.worldFromCamera.applying(
            to: Point3D(x: 0.005, y: 0.005, z: -1)
        )
        #expect(firstPoint.isApproximatelyEqual(to: Point3D(x: -0.005, y: -0.005, z: 1)))
        let inspection = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let timeline = try #require(inspection.evidence.stages.first(where: { $0.stage == .captureTimeline }))
        #expect(timeline.metrics.values["m11StructuralQualification"] == "satisfied")
        #expect(timeline.metrics.values["m1AdmissionQualification"] == "notApplicableExternalSource")
    }

    @Test("Rejects a source asset whose bytes no longer match the intake manifest")
    func rejectsChangedSourceAsset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifestURL = try fixture.makeManifest(includeReference: false)
        try Data("changed".utf8).write(to: fixture.source.appending(path: "camera.pincam"))

        await #expect(throws: PublicRGBDBenchmarkIntakeError.assetIntegrityMismatch("camera.pincam")) {
            try await PublicRGBDBenchmarkIntake().importDataset(
                manifestURL: manifestURL,
                sourceRoot: fixture.source,
                outputRoot: fixture.output
            )
        }
    }

    @Test("Replays schema one manifests with the historical camera basis")
    func replaysLegacySchemaOneCameraBasis() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifestURL = try fixture.makeManifest(
            includeReference: false,
            schemaVersion: 1,
            cameraCoordinateConvention: nil
        )
        _ = try await PublicRGBDBenchmarkIntake().importDataset(
            manifestURL: manifestURL,
            sourceRoot: fixture.source,
            outputRoot: fixture.output
        )
        let store = try FileAssetStore(rootURL: fixture.output)
        let packageURL = try await store.packageURL(for: fixture.scanID)
        let manifest = try await store.loadManifest(id: fixture.scanID)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: manifest,
            integrity: try await store.validatePackage(id: fixture.scanID)
        )
        let point = try archive.readKeyframe(at: 0).depth.worldFromCamera.applying(
            to: Point3D(x: 0.005, y: 0.005, z: -1)
        )
        #expect(point.isApproximatelyEqual(to: Point3D(x: 0.005, y: 0.005, z: -1)))
    }

    @Test("Rejects schema two manifests that omit the camera coordinate convention")
    func rejectsMissingSchemaTwoCoordinateConvention() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifestURL = try fixture.makeManifest(includeReference: false)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object.removeValue(forKey: "cameraCoordinateConvention")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        await #expect(throws: PublicRGBDBenchmarkIntakeError.invalidManifest("public RGB-D contract")) {
            try await PublicRGBDBenchmarkIntake().importDataset(
                manifestURL: manifestURL,
                sourceRoot: fixture.source,
                outputRoot: fixture.output
            )
        }
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let output: URL
    let scanID = UUID(uuidString: "62755609-DC70-4C82-A14B-109E79C27F49")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "PublicRGBDIntake-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        source = root.appending(path: "source", directoryHint: .isDirectory)
        output = root.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeManifest(
        includeReference: Bool,
        schemaVersion: Int = PublicRGBDBenchmarkIntakeManifest.currentSchemaVersion,
        cameraCoordinateConvention: PublicRGBDCameraCoordinateConvention? = .opticalPositiveXYZ
    ) throws -> URL {
        let frames = [0.0, 0.1].enumerated().map { index, timestamp in
            PublicRGBDSelectedFrame(
                timestamp: timestamp,
                colorPath: "color-\(index).png",
                depthPath: "depth-\(index).png",
                confidencePath: "confidence-\(index).png",
                intrinsicsPath: "camera.pincam"
            )
        }
        try Data("2 2 100 100 0.5 0.5\n".utf8).write(to: source.appending(path: "camera.pincam"))
        try Data("0 0 0 0 0 0 0\n0.1 0 0 0 -0.1 0 0\n".utf8).write(
            to: source.appending(path: "camera.traj")
        )
        for index in frames.indices {
            try writeRGBPNG(
                to: source.appending(path: "color-\(index).png"),
                rgba: [
                    255, 0, 0, 255, 0, 255, 0, 255,
                    0, 0, 255, 255, 255, 255, 255, 255
                ]
            )
            let depths: [UInt16] = index == 0 ? [1_000, 1_100, 0, 1_300] : [1_050, 1_150, 1_250, 1_350]
            try writeGray16PNG(to: source.appending(path: "depth-\(index).png"), values: depths)
            try writeGray8PNG(
                to: source.appending(path: "confidence-\(index).png"),
                values: [2, 2, 1, 0]
            )
        }
        if includeReference {
            try Data("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n".utf8).write(
                to: source.appending(path: "reference.ply")
            )
        }

        var identities: [PublicRGBDAssetIdentity] = [
            try identity(.cameraIntrinsics, "camera.pincam"),
            try identity(.cameraTrajectory, "camera.traj")
        ]
        for index in frames.indices {
            identities.append(try identity(.colorPNG, "color-\(index).png"))
            identities.append(try identity(.depthMillimetersUInt16PNG, "depth-\(index).png"))
            identities.append(try identity(.confidenceUInt8PNG, "confidence-\(index).png"))
        }
        if includeReference { identities.append(try identity(.referenceGeometry, "reference.ply")) }
        let manifest = PublicRGBDBenchmarkIntakeManifest(
            schemaVersion: schemaVersion,
            intakeID: "fixture-scene-v1",
            dataset: .arkitScenesRawV1,
            datasetRevision: "fixture-revision",
            sourceURL: "https://github.com/apple/ARKitScenes",
            licenseURL: "https://github.com/apple/ARKitScenes/blob/main/LICENSE",
            licenseTermsAccepted: true,
            localEvaluationOnly: true,
            split: "fixture",
            sceneID: "fixture-scene",
            outputScanID: scanID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            trajectoryPath: "camera.traj",
            trajectoryConvention: .worldToCameraAxisAngleRadians,
            cameraCoordinateConvention: cameraCoordinateConvention,
            maximumPoseTimestampDeltaSeconds: 0.001,
            frames: frames,
            assets: identities
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = root.appending(path: "intake.json")
        try encoder.encode(manifest).write(to: url)
        return url
    }

    private func identity(_ kind: PublicRGBDAssetKind, _ path: String) throws -> PublicRGBDAssetIdentity {
        let data = try Data(contentsOf: source.appending(path: path))
        return PublicRGBDAssetIdentity(
            kind: kind,
            relativePath: path,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func writeRGBPNG(to url: URL, rgba: [UInt8]) throws {
        try rgba.withUnsafeBytes { bytes in
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(
                    width: 2,
                    height: 2,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: 8,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else { throw FixtureError.imageCreation }
            try writePNG(image, to: url)
        }
    }

    private func writeGray8PNG(to url: URL, values: [UInt8]) throws {
        guard let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw FixtureError.imageCreation }
        try writePNG(image, to: url)
    }

    private func writeGray16PNG(to url: URL, values: [UInt16]) throws {
        let data = values.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo.byteOrder16Little,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw FixtureError.imageCreation }
        try writePNG(image, to: url)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw FixtureError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.imageCreation }
    }
}

private enum FixtureError: Error {
    case imageCreation
}
