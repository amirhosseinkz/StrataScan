import Foundation
import Testing
@testable import StrataCore

@Suite("Calibrated RGB-D keyframe archive")
struct CalibratedRGBDKeyframeArchiveTests {
    @Test("An integrity-valid package replays exact calibrated RGB-depth-confidence values")
    func reopensAndReplaysWithoutARKit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let captureRoot = root.appending(path: "capture-staging", directoryHint: .isDirectory)
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: captureRoot)
        let source = keyframe(
            timestamp: 12.5,
            transform: .translation(x: 1, y: 2, z: 3),
            depthValues: [1, Float(bitPattern: 0x7FC0_0123), .infinity, 4],
            confidence: [2, 1, 0, 2],
            colors: [
                PointCloudColor(red: 1, green: 2, blue: 3),
                PointCloudColor(red: 4, green: 5, blue: 6),
                PointCloudColor(red: 7, green: 8, blue: 9),
                PointCloudColor(red: 10, green: 11, blue: 12)
            ]
        )

        let record = try await writer.append(source)
        let firstSummary = try await writer.finish()
        let secondSummary = try await writer.finish()
        #expect(firstSummary == secondSummary)

        let scanID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite")),
            assetStore: assetStore
        )
        let paths = [
            CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            record.depthPath,
            record.confidencePath,
            record.rgbPath
        ]
        let telemetry = CaptureTelemetry(
            calibratedKeyframeAcceptanceCounts: [CalibratedKeyframeAcceptanceReason.initialFrame.rawValue: 1]
        )
        try await repository.save(
            scan: ScanMetadata(
                id: scanID,
                displayName: "Replay fixture",
                status: .completed,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: timestamp,
                updatedAt: timestamp,
                captureTelemetry: telemetry
            ),
            assets: paths.map {
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: $0,
                    fileURL: captureRoot.appending(path: $0),
                    spatialReference: .arWorld
                )
            }
        )

        let reopened = try #require(try await repository.reopen(id: scanID))
        let packageURL = try await assetStore.packageURL(for: scanID)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: reopened.manifest,
            integrity: reopened.integrity
        )
        let replay = try archive.records.indices.map { try archive.readKeyframe(at: $0) }

        #expect(reopened.integrity.isValid)
        #expect(reopened.manifest.captureTelemetry == telemetry)
        #expect(replay.count == 1)
        #expect(archive.sourceArchiveSHA256.count == 64)
        #expect(archive.sourceArchiveSHA256 != archive.sourceIndexSHA256)
        #expect(replay[0].record == record)
        #expect(replay[0].depth.depthMeters.map(\.bitPattern) == source.depth.depthMeters.map(\.bitPattern))
        #expect(replay[0].depth.confidence == source.depth.confidence)
        #expect(replay[0].depth.observedColors == source.depth.observedColors)
        #expect(replay[0].depth.calibration == source.depth.calibration)
        #expect(replay[0].depth.worldFromCamera == source.depth.worldFromCamera)
    }

    @Test("Replay refuses a package after a payload checksum failure")
    func rejectsCorruptPackage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let captureRoot = root.appending(path: "capture-staging", directoryHint: .isDirectory)
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: captureRoot)
        let record = try await writer.append(keyframe())
        _ = try await writer.finish()
        let scanID = UUID()
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let manifest = try await assetStore.finalize(
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: .now,
                updatedAt: .now
            ),
            assets: [
                CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
                record.depthPath,
                record.confidencePath,
                record.rgbPath
            ].map {
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: $0,
                    fileURL: captureRoot.appending(path: $0),
                    spatialReference: .arWorld
                )
            }
        )
        let packageURL = try await assetStore.packageURL(for: scanID)
        let validIntegrity = try await assetStore.validatePackage(id: scanID)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: manifest,
            integrity: validIntegrity
        )
        try Data([0, 0, 0, 0]).write(
            to: packageURL.appending(path: record.confidencePath),
            options: .atomic
        )
        #expect(throws: CalibratedRGBDKeyframeArchiveError.invalidPayload(record.confidencePath)) {
            try archive.readKeyframe(at: 0)
        }
        let integrity = try await assetStore.validatePackage(id: scanID)

        #expect(!integrity.isValid)
        #expect(throws: CalibratedRGBDKeyframeArchiveError.packageIntegrityFailed) {
            try CalibratedRGBDKeyframeArchiveReader().read(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity
            )
        }
    }

    @Test("Cancellation closes the keyframe writer")
    func cancellationStopsArchiveWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: root)

        await writer.cancel()

        await #expect(throws: CalibratedRGBDKeyframeArchiveError.alreadyClosed) {
            try await writer.append(keyframe())
        }
    }

    @Test("Schema-v2 writes require complete synchronized evidence while schema-v1 records remain decodable")
    func enforcesVersionedEvidenceContract() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: root)
        let authoritative = keyframe(timestamp: 3)
        let missingContract = CalibratedRGBDKeyframeSample(
            metadata: authoritative.metadata,
            depth: authoritative.depth,
            acceptanceReason: authoritative.acceptanceReason
        )

        await #expect(throws: CalibratedRGBDKeyframeArchiveError.invalidSample) {
            try await writer.append(missingContract)
        }

        var mismatched = authoritative
        mismatched.evidenceContract?.timestamps.confidence = 4
        await #expect(throws: CalibratedRGBDKeyframeArchiveError.invalidSample) {
            try await writer.append(mismatched)
        }

        let legacy = CalibratedRGBDKeyframeRecord(
            index: 1,
            metadata: authoritative.metadata,
            acceptanceReason: .initialFrame,
            depthWidth: 2,
            depthHeight: 2,
            depthPath: "capture/keyframes/legacy.depth-f32le",
            confidencePath: "capture/keyframes/legacy.confidence-u8",
            rgbPath: "capture/keyframes/legacy.rgb-u8"
        )
        let decoded = try JSONDecoder().decode(
            CalibratedRGBDKeyframeRecord.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.evidenceContract == nil)
    }

    @Test("Telemetry accounting reconciles decisions and lifecycle without retaining unbounded samples")
    func recordsBoundedLifecycleEvidence() {
        var telemetry = CaptureTelemetry()
        for index in 0..<140 {
            telemetry.record(.calibratedKeyframeCandidate(CalibratedKeyframeEvidence(
                timestamp: Double(index),
                confidenceRatio: 1,
                overlapRatio: 1,
                newCoverageRatio: 0,
                poseBaselineMeters: 0,
                cadenceSeconds: 1
            )))
        }
        telemetry.record(.initialFrame)
        telemetry.record(.calibratedKeyframeRejected(.blur))
        telemetry.recordTracking(.limited)
        telemetry.recordInterruptionBegan()
        telemetry.recordInterruptionEnded()
        telemetry.recordFinalization()
        telemetry.recordFinalization()

        #expect(telemetry.calibratedKeyframeCandidateCount == 2)
        #expect(telemetry.evidenceSamples.count == 128)
        #expect(telemetry.evidenceSamples.first?.timestamp == 12)
        #expect(telemetry.trackingStateCounts?[FrameTrackingState.limited.rawValue] == 1)
        #expect(telemetry.interruptionBeganCount == 1)
        #expect(telemetry.interruptionEndedCount == 1)
        #expect(telemetry.finalizationCount == 1)
    }

    @Test("Admission accepts motion, surface novelty, and the time ceiling but rejects duplicates")
    func selectsUsefulCalibratedFrames() {
        var admission = CalibratedKeyframeAdmission(
            minimumTranslationMeters: 0.25,
            minimumRotationRadians: .pi / 9,
            maximumIntervalSeconds: 5,
            minimumNovelDepthFraction: 0.25
        )

        #expect(admission.evaluate(metadata: metadata(timestamp: 0), depth: depth(timestamp: 0)) == .accepted(.initialFrame))
        #expect(admission.evaluate(metadata: metadata(timestamp: 1), depth: depth(timestamp: 1)) == .rejected(.duplicate))
        #expect(admission.evaluate(
            metadata: metadata(timestamp: 2),
            depth: depth(timestamp: 2, values: [2, 2, 2, 2])
        ) == .accepted(.surfaceNovelty))
        #expect(admission.evaluate(
            metadata: metadata(timestamp: 3, transform: .translation(x: 0.3, y: 0, z: 0)),
            depth: depth(timestamp: 3, transform: .translation(x: 0.3, y: 0, z: 0), values: [2, 2, 2, 2])
        ) == .accepted(.cameraMotion))
        #expect(admission.evaluate(
            metadata: metadata(timestamp: 9, transform: .translation(x: 0.3, y: 0, z: 0)),
            depth: depth(timestamp: 9, transform: .translation(x: 0.3, y: 0, z: 0), values: [2, 2, 2, 2])
        ) == .accepted(.timeCeiling))
    }

    @Test("Admission reports incomplete RGB and degraded tracking")
    func rejectsIncompleteInputs() {
        var admission = CalibratedKeyframeAdmission()
        var missingRGB = depth(timestamp: 0)
        missingRGB.observedColors = []
        var limited = metadata(timestamp: 0)
        limited.tracking = .limited

        #expect(admission.evaluate(metadata: metadata(timestamp: 0), depth: missingRGB) == .rejected(.missingRGB))
        #expect(admission.evaluate(metadata: limited, depth: depth(timestamp: 0)) == .rejected(.tracking))
    }

    @Test("Evidence admission requires mapping and usable confidence before accepting a frame")
    func evidenceAdmissionRejectsUnreadyOrLowConfidenceFrames() {
        var admission = CalibratedKeyframeAdmission(configuration: .default)
        var unmapped = metadata(timestamp: 0)
        unmapped.worldMapping = .notAvailable
        #expect(admission.evaluate(metadata: unmapped, depth: depth(timestamp: 0)) == .rejected(.mappingNotReady))
        #expect(admission.evaluate(
            metadata: metadata(timestamp: 1),
            depth: depth(timestamp: 1, confidence: [0, 0, 0, 0])
        ) == .rejected(.lowConfidence))
        #expect(admission.evaluate(metadata: metadata(timestamp: 2), depth: depth(timestamp: 2)) == .accepted(.initialFrame))
        #expect(admission.lastEvidence?.confidenceRatio == 1)
    }

    @Test("Evidence qualification reports recorded admission facts without inventing accuracy")
    func evidenceQualificationSummarizesPersistedTelemetry() {
        var telemetry = CaptureTelemetry()
        telemetry.record(.calibratedKeyframeCandidate(
            CalibratedKeyframeEvidence(
                timestamp: 1,
                confidenceRatio: 0.75,
                overlapRatio: 0.24,
                newCoverageRatio: 0.04,
                poseBaselineMeters: 0.21,
                cadenceSeconds: 0.5
            )
        ))
        telemetry.record(.initialFrame)
        telemetry.record(.calibratedKeyframeCandidate(
            CalibratedKeyframeEvidence(
                timestamp: 2,
                confidenceRatio: 0.85,
                overlapRatio: 0.18,
                newCoverageRatio: 0.12,
                poseBaselineMeters: 0.24,
                cadenceSeconds: 0.8
            )
        ))
        telemetry.record(CalibratedKeyframeAcceptanceReason.cameraMotion)
        telemetry.record(.calibratedKeyframeRejected(.blur))

        let qualification = telemetry.evidenceQualification
        #expect(qualification.candidateCount == 3)
        #expect(qualification.acceptedCount == 2)
        #expect(qualification.rejectionCounts["blur"] == 1)
        #expect(qualification.meanCadenceSeconds == 0.65)
        #expect(qualification.meanConfidenceRatio == 0.8)
        #expect(qualification.isEvidenceSufficientForProcessing)

        let emptyQualification = CaptureTelemetry().evidenceQualification
        #expect(emptyQualification.meanCadenceSeconds == nil)
        #expect(!emptyQualification.isEvidenceSufficientForProcessing)
    }

    private func keyframe(
        timestamp: TimeInterval = 1,
        transform: Transform4x4 = .identity,
        depthValues: [Float] = [1, 1, 1, 1],
        confidence: [UInt8] = [2, 2, 2, 2],
        colors: [PointCloudColor] = Array(
            repeating: PointCloudColor(red: 10, green: 20, blue: 30),
            count: 4
        )
    ) -> CalibratedRGBDKeyframeSample {
        authoritativeTestKeyframe(
            metadata: metadata(timestamp: timestamp, transform: transform),
            depth: depth(
                timestamp: timestamp,
                transform: transform,
                values: depthValues,
                confidence: confidence,
                colors: colors
            )
        )
    }

    private func metadata(
        timestamp: TimeInterval,
        transform: Transform4x4 = .identity
    ) -> FrameMetadata {
        FrameMetadata(
            timestamp: timestamp,
            videoTimestamp: nil,
            imageWidth: 4,
            imageHeight: 4,
            intrinsics: CameraIntrinsics(
                imageWidth: 4,
                imageHeight: 4,
                fx: 2,
                fy: 2,
                cx: 1.5,
                cy: 1.5
            ),
            worldFromCamera: transform,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false,
            displayOrientation: .right
        )
    }

    private func depth(
        timestamp: TimeInterval,
        transform: Transform4x4 = .identity,
        values: [Float] = [1, 1, 1, 1],
        confidence: [UInt8] = [2, 2, 2, 2],
        colors: [PointCloudColor] = Array(
            repeating: PointCloudColor(red: 10, green: 20, blue: 30),
            count: 4
        )
    ) -> DepthFrameSample {
        DepthFrameSample(
            width: 2,
            height: 2,
            depthMeters: values,
            confidence: confidence,
            observedColors: colors.map(Optional.some),
            calibration: metadata(timestamp: timestamp, transform: transform).intrinsics,
            worldFromCamera: transform,
            timestamp: timestamp
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanRGBDArchive-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
