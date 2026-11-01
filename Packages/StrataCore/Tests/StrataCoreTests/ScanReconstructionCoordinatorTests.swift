import Foundation
import Testing
@testable import StrataCore

@Suite("Scan reconstruction coordinator")
struct ScanReconstructionCoordinatorTests {
    @Test("Duplicate enqueues coalesce into one active job")
    func coalescesDuplicateEnqueues() async throws {
        let fixture = try Fixture(blocksRunner: true)
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.runner.runCount == 1 })
        #expect(await fixture.coordinator.startedJobCount() == 1)

        await fixture.runner.release()
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .ready })
    }

    @Test("Only one reconstruction job executes globally")
    func limitsGlobalConcurrency() async throws {
        let fixture = try Fixture(blocksRunner: true)
        defer { fixture.remove() }
        let first = UUID()
        let second = UUID()

        _ = await fixture.coordinator.enqueue(scanID: first)
        _ = await fixture.coordinator.enqueue(scanID: second)
        #expect(await eventually { await fixture.runner.runCount == 1 })
        #expect(await fixture.runner.maximumActiveCount == 1)

        await fixture.runner.release()
        #expect(await eventually { await fixture.runner.runCount == 2 })
        #expect(await eventually { await fixture.coordinator.status(scanID: second).stage == .ready })
        #expect(await fixture.runner.maximumActiveCount == 1)
    }

    @Test("Application inactivity pauses and active lifecycle resumes")
    func pausesForApplicationLifecycle() async throws {
        let fixture = try Fixture(blocksRunner: true)
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.runner.runCount == 1 })
        await fixture.coordinator.setApplicationActive(false)
        let paused = await fixture.coordinator.status(scanID: scanID)
        #expect(paused.stage == .paused)
        #expect(paused.failureCategory == .applicationInactive)

        await fixture.coordinator.setApplicationActive(true)
        #expect(await eventually { await fixture.runner.runCount == 2 })
        await fixture.runner.release()
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .ready })
    }

    @Test("Resource pressure pauses until an explicit retry")
    func pausesForResourcePressure() async throws {
        let fixture = try Fixture(
            resources: ScanReconstructionResourceSnapshot(
                availableStorageBytes: 1,
                thermalPressure: .nominal,
                isLowPowerModeEnabled: false
            )
        )
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .paused })
        #expect(await fixture.coordinator.status(scanID: scanID).failureCategory == .insufficientStorage)
        #expect(await fixture.runner.runCount == 0)

        await fixture.resources.set(.available)
        _ = await fixture.coordinator.retry(scanID: scanID)
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .ready })
        #expect(await fixture.runner.runCount == 1)
    }

    @Test("Terminal failures do not automatically loop")
    func terminalFailureDoesNotLoop() async throws {
        let fixture = try Fixture(outcomes: [.terminal(.invalidArchive)])
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .failedTerminal })
        _ = await fixture.coordinator.enqueue(scanID: scanID, automatic: true)

        #expect(await fixture.runner.runCount == 1)
        #expect(await fixture.coordinator.status(scanID: scanID).failureCategory == .invalidArchive)
    }

    @Test("Retryable failures wait for explicit retry and then resume")
    func retryableFailureRequiresExplicitRetry() async throws {
        let fixture = try Fixture(outcomes: [.retryable(.interruptedIO), .success])
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .failedRetryable })
        _ = await fixture.coordinator.enqueue(scanID: scanID, automatic: true)
        #expect(await fixture.runner.runCount == 1)

        _ = await fixture.coordinator.retry(scanID: scanID)
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .ready })
        #expect(await fixture.runner.runCount == 2)
    }

    @Test("Thermal pressure and low-power mode pause before the runner")
    func pausesForThermalAndLowPowerConditions() async throws {
        let constrainedResources = [
            ScanReconstructionResourceSnapshot(
                availableStorageBytes: ScanReconstructionCoordinator.provisionalMinimumAvailableStorageBytes * 2,
                thermalPressure: .serious,
                isLowPowerModeEnabled: false
            ),
            ScanReconstructionResourceSnapshot(
                availableStorageBytes: ScanReconstructionCoordinator.provisionalMinimumAvailableStorageBytes * 2,
                thermalPressure: .nominal,
                isLowPowerModeEnabled: true
            )
        ]
        let expectedCategories: [ScanReconstructionFailureCategory] = [.thermalPressure, .lowPower]

        for (resources, expectedCategory) in zip(constrainedResources, expectedCategories) {
            let fixture = try Fixture(resources: resources)
            defer { fixture.remove() }
            let scanID = UUID()

            _ = await fixture.coordinator.enqueue(scanID: scanID)
            #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .paused })
            #expect(await fixture.coordinator.status(scanID: scanID).failureCategory == expectedCategory)
            #expect(await fixture.runner.runCount == 0)
        }
    }

    @Test("Explicit cancellation awaits the active job and records a retryable state")
    func cancelsActiveJob() async throws {
        let fixture = try Fixture(blocksRunner: true)
        defer { fixture.remove() }
        let scanID = UUID()

        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.runner.runCount == 1 })
        await fixture.coordinator.cancelAndWait(scanID: scanID)
        let status = await fixture.coordinator.status(scanID: scanID)

        #expect(status.stage == .failedRetryable)
        #expect(status.failureCategory == .cancelled)
    }

    @Test("Startup resumes an interrupted durable stage")
    func resumesInterruptedDurableStage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let directory = root.appending(path: scanID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = ScanReconstructionStatus(scanID: scanID, stage: .extractingSurface)
        try JSONEncoder().encode(status).write(
            to: directory.appending(path: "coordinator-state.json"),
            options: .atomic
        )
        let runner = TestReconstructionRunner()
        let coordinator = try ScanReconstructionCoordinator(
            runner: runner,
            resourceMonitor: MutableResourceMonitor(.available),
            processingRootURL: root
        )

        await coordinator.resumePendingJobs()

        #expect(await eventually { await coordinator.status(scanID: scanID).stage == .ready })
        #expect(await runner.runCount == 1)
    }

    @Test("A symbolic-link processing root is rejected")
    func rejectsSymbolicLinkRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ScanReconstructionJobError.terminal(.invalidDerivedPath)) {
            _ = try ScanReconstructionCoordinator(
                runner: TestReconstructionRunner(),
                resourceMonitor: MutableResourceMonitor(.available),
                processingRootURL: link
            )
        }
    }

    @Test("A symbolic-link scan directory cannot receive coordinator state")
    func rejectsSymbolicLinkScanStateDirectory() async throws {
        let root = try temporaryDirectory()
        let target = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let scanID = UUID()
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: scanID.uuidString, directoryHint: .isDirectory),
            withDestinationURL: target
        )
        let runner = TestReconstructionRunner()
        let coordinator = try ScanReconstructionCoordinator(
            runner: runner,
            resourceMonitor: MutableResourceMonitor(.available),
            processingRootURL: root
        )

        let status = await coordinator.enqueue(scanID: scanID)

        #expect(status.stage == .failedTerminal)
        #expect(status.failureCategory == .invalidDerivedPath)
        #expect(await runner.runCount == 0)
        #expect(!FileManager.default.fileExists(
            atPath: target.appending(path: "coordinator-state.json").path
        ))
    }

    @Test("A rapid active transition resumes a lifecycle-cancelled job")
    func activeTransitionWinsCancellationRace() async throws {
        let fixture = try Fixture(blocksRunner: true, delaysCancellation: true)
        defer { fixture.remove() }
        let scanID = UUID()
        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.runner.runCount == 1 })

        let inactive = Task { await fixture.coordinator.setApplicationActive(false) }
        #expect(await eventually { await fixture.runner.didReceiveCancellation })
        await fixture.coordinator.setApplicationActive(true)
        await fixture.runner.releaseCancellation()
        await inactive.value

        #expect(await eventually { await fixture.runner.runCount == 2 })
        await fixture.runner.release()
        #expect(await eventually { await fixture.coordinator.status(scanID: scanID).stage == .ready })
    }

    @Test("A completed cancellation request cannot affect a later job")
    func clearsLifecyclePauseAfterCompletionWinsCancellation() async throws {
        let fixture = try Fixture(blocksRunner: true, ignoredCancellationCount: 1)
        defer { fixture.remove() }
        let scanID = UUID()
        _ = await fixture.coordinator.enqueue(scanID: scanID)
        #expect(await eventually { await fixture.runner.runCount == 1 })

        await fixture.coordinator.setApplicationActive(false)
        #expect(await fixture.coordinator.status(scanID: scanID).stage == .ready)
        await fixture.coordinator.setApplicationActive(true)
        _ = await fixture.coordinator.enqueue(scanID: scanID, automatic: false)
        #expect(await eventually { await fixture.runner.runCount == 2 })
        await fixture.coordinator.cancelAndWait(scanID: scanID)
        let cancelled = await fixture.coordinator.status(scanID: scanID)

        #expect(cancelled.stage == .failedRetryable)
        #expect(cancelled.failureCategory == .cancelled)
    }

    @Test("A finalized RGB-D package is promoted without mutating its source assets")
    func runsFinalizedPackageThroughViewerLoadablePromotion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let sample = reconstructionKeyframe()
        let archiveWriter = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: staging)
        let record = try await archiveWriter.append(sample)
        _ = try await archiveWriter.finish()
        let canonicalURL = staging.appending(path: CanonicalSpatialChunkStore.relativePath)
        let canonicalStore = try CanonicalSpatialChunkStore(destinationURL: canonicalURL)
        _ = try await canonicalStore.append(canonicalSamples(for: sample.depth))
        _ = try await canonicalStore.finish()

        let scanID = UUID()
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "packages"))
        let repository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite")),
            assetStore: assetStore
        )
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let paths = [
            CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            record.depthPath,
            record.confidencePath,
            record.rgbPath,
            CanonicalSpatialChunkStore.relativePath
        ]
        try await repository.save(
            scan: ScanMetadata(
                id: scanID,
                displayName: "Reconstruction fixture",
                status: .completed,
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            assets: paths.map {
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: $0,
                    fileURL: staging.appending(path: $0),
                    spatialReference: .arWorld
                )
            }
        )
        let packageURL = try await assetStore.packageURL(for: scanID)
        let packageBytesBefore = try await assetStore.packageByteCount(id: scanID)
        let processingRoot = root.appending(path: "processing", directoryHint: .isDirectory)
        let derivedRoot = root.appending(path: "derived", directoryHint: .isDirectory)
        let processedStore = try ProcessedSurfaceStore(
            rootURL: derivedRoot,
            processingRootURL: processingRoot
        )
        let runner = LocalScanReconstructionRunner(
            repository: repository,
            assetStore: assetStore,
            processedSurfaceStore: processedStore,
            processingRootURL: processingRoot,
            derivedRootURL: derivedRoot
        )

        let source = try await runner.run(scanID: scanID) { _ in }
        let reopened = try #require(try await repository.reopen(id: scanID))
        let surface = try await processedStore.loadProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: reopened.manifest,
            integrity: reopened.integrity
        )

        #expect(source.keyframeCount == 1)
        #expect(surface.prefix.configuration == .productionBalanced)
        #expect(surface.sourceVertexCount > 0)
        #expect(surface.sourceTriangleCount > 0)
        #expect(surface.isComplete)
        #expect(try await assetStore.packageByteCount(id: scanID) == packageBytesBefore)
        #expect((try await assetStore.validatePackage(id: scanID)).isValid)

        let changedExtractionConfiguration = try TSDFSurfaceExtractionConfiguration(
            minimumVoxelWeight: 2
        )
        let changedRunner = LocalScanReconstructionRunner(
            repository: repository,
            assetStore: assetStore,
            processedSurfaceStore: processedStore,
            processingRootURL: processingRoot,
            derivedRootURL: derivedRoot,
            extractionConfiguration: changedExtractionConfiguration
        )
        await #expect(throws: ScanReconstructionJobError.self) {
            _ = try await changedRunner.run(scanID: scanID) { _ in }
        }

        let framesURL = processingRoot
            .appending(path: scanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "tsdf", directoryHint: .isDirectory)
            .appending(path: "frames", directoryHint: .isDirectory)
        let escapedURL = root.appending(path: "escaped-tsdf", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: framesURL)
        try FileManager.default.createDirectory(at: escapedURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: framesURL, withDestinationURL: escapedURL)
        await #expect(throws: ScanReconstructionJobError.terminal(.invalidDerivedPath)) {
            _ = try await runner.run(scanID: scanID) { _ in }
        }
    }

    private struct Fixture {
        let root: URL
        let runner: TestReconstructionRunner
        let resources: MutableResourceMonitor
        let coordinator: ScanReconstructionCoordinator

        init(
            blocksRunner: Bool = false,
            delaysCancellation: Bool = false,
            ignoredCancellationCount: Int = 0,
            outcomes: [TestReconstructionRunner.Outcome] = [.success],
            resources: ScanReconstructionResourceSnapshot = .available
        ) throws {
            root = try temporaryDirectory()
            runner = TestReconstructionRunner(
                blocked: blocksRunner,
                delaysCancellation: delaysCancellation,
                ignoredCancellationCount: ignoredCancellationCount,
                outcomes: outcomes
            )
            self.resources = MutableResourceMonitor(resources)
            coordinator = try ScanReconstructionCoordinator(
                runner: runner,
                resourceMonitor: self.resources,
                processingRootURL: root
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private func reconstructionKeyframe() -> CalibratedRGBDKeyframeSample {
    let width = 16
    let height = 16
    let intrinsics = CameraIntrinsics(
        imageWidth: width,
        imageHeight: height,
        fx: 100,
        fy: 100,
        cx: 7.5,
        cy: 7.5
    )
    let metadata = FrameMetadata(
        timestamp: 1,
        videoTimestamp: nil,
        imageWidth: width,
        imageHeight: height,
        intrinsics: intrinsics,
        worldFromCamera: .identity,
        tracking: .normal,
        worldMapping: .mapped,
        isTextureSourceCandidate: true
    )
    let color = PointCloudColor(red: 40, green: 80, blue: 120)
    return authoritativeTestKeyframe(
        metadata: metadata,
        depth: DepthFrameSample(
            width: width,
            height: height,
            depthMeters: Array(repeating: 1, count: width * height),
            confidence: Array(repeating: 2, count: width * height),
            observedColors: Array(repeating: color, count: width * height),
            calibration: intrinsics,
            worldFromCamera: .identity,
            timestamp: 1
        )
    )
}

private func canonicalSamples(for depth: DepthFrameSample) -> [RGBDPointSample] {
    (0..<depth.height).flatMap { y in
        (0..<depth.width).map { x in
            let distance = depth.depthMeters[y * depth.width + x]
            return RGBDPointSample(
                position: Point3D(
                    x: -((Float(x) - depth.calibration.cx) / depth.calibration.fx) * distance,
                    y: -((Float(y) - depth.calibration.cy) / depth.calibration.fy) * distance,
                    z: -distance
                ),
                confidence: depth.confidence[y * depth.width + x],
                color: depth.observedColors[y * depth.width + x]
            )
        }
    }
}

private actor TestReconstructionRunner: ScanReconstructionJobRunning {
    enum Outcome: Sendable {
        case success
        case retryable(ScanReconstructionFailureCategory)
        case terminal(ScanReconstructionFailureCategory)
    }

    private(set) var runCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var didReceiveCancellation = false
    private var activeCount = 0
    private var blocked: Bool
    private var delaysCancellation: Bool
    private var ignoredCancellationCount: Int
    private let outcomes: [Outcome]

    init(
        blocked: Bool = false,
        delaysCancellation: Bool = false,
        ignoredCancellationCount: Int = 0,
        outcomes: [Outcome] = [.success]
    ) {
        self.blocked = blocked
        self.delaysCancellation = delaysCancellation
        self.ignoredCancellationCount = ignoredCancellationCount
        self.outcomes = outcomes
    }

    func run(
        scanID: UUID,
        event: @escaping @Sendable (ScanReconstructionJobEvent) async throws -> Void
    ) async throws -> TSDFReconstructionSource {
        runCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        let source = TSDFReconstructionSource(
            scanID: scanID,
            keyframeIndexSHA256: String(repeating: "a", count: 64),
            calibratedArchiveSHA256: String(repeating: "b", count: 64),
            keyframeCount: 2
        )
        try await event(.verifyingSource)
        try await event(.sourceVerified(source))
        do {
            while blocked {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch is CancellationError {
            didReceiveCancellation = true
            if ignoredCancellationCount > 0 {
                ignoredCancellationCount -= 1
                return source
            }
            while delaysCancellation {
                await Task.yield()
            }
            throw CancellationError()
        }
        switch outcomes[min(runCount - 1, outcomes.count - 1)] {
        case .success:
            return source
        case let .retryable(category):
            throw ScanReconstructionJobError.retryable(category)
        case let .terminal(category):
            throw ScanReconstructionJobError.terminal(category)
        }
    }

    func release() {
        blocked = false
    }

    func releaseCancellation() {
        delaysCancellation = false
    }
}

private actor MutableResourceMonitor: ScanReconstructionResourceMonitoring {
    private var value: ScanReconstructionResourceSnapshot

    init(_ value: ScanReconstructionResourceSnapshot) {
        self.value = value
    }

    func snapshot() async -> ScanReconstructionResourceSnapshot { value }

    func set(_ value: ScanReconstructionResourceSnapshot) {
        self.value = value
    }
}

private extension ScanReconstructionResourceSnapshot {
    static let available = ScanReconstructionResourceSnapshot(
        availableStorageBytes: ScanReconstructionCoordinator.provisionalMinimumAvailableStorageBytes * 2,
        thermalPressure: .nominal,
        isLowPowerModeEnabled: false
    )
}

private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "StrataScanReconstructionCoordinator-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
