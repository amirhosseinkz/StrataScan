import Foundation

public enum ScanReconstructionStage: String, Codable, Equatable, Sendable {
    case queued
    case verifyingSource
    case reconstructing
    case extractingSurface
    case validatingSurface
    case promotingSurface
    case ready
    case paused
    case unavailable
    case failedRetryable
    case failedTerminal
}

public enum ScanReconstructionFailureCategory: String, Codable, Equatable, Sendable {
    case cancelled
    case applicationInactive
    case insufficientStorage
    case thermalPressure
    case lowPower
    case interruptedIO
    case missingArchive
    case unsupportedLegacyPackage
    case invalidPackageIntegrity
    case invalidArchive
    case sourceIdentityMismatch
    case invalidDerivedPath
    case surfaceValidation
    case promotionConflict
}

public struct ScanReconstructionStatus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var scanID: UUID
    public var source: TSDFReconstructionSource?
    public var reconstructionConfiguration: TSDFReconstructionConfiguration
    public var extractionConfiguration: TSDFSurfaceExtractionConfiguration
    public var stage: ScanReconstructionStage
    public var completedFrameCount: Int
    public var totalFrameCount: Int
    public var completedSubmapCount: Int
    public var totalSubmapCount: Int
    public var lastSafeUpdate: Date
    public var retryCount: Int
    public var failureCategory: ScanReconstructionFailureCategory?
    public var promotedSurfaceValid: Bool

    public init(
        scanID: UUID,
        source: TSDFReconstructionSource? = nil,
        reconstructionConfiguration: TSDFReconstructionConfiguration = .productionBalanced,
        extractionConfiguration: TSDFSurfaceExtractionConfiguration = .default,
        stage: ScanReconstructionStage = .queued,
        completedFrameCount: Int = 0,
        totalFrameCount: Int = 0,
        completedSubmapCount: Int = 0,
        totalSubmapCount: Int = 0,
        lastSafeUpdate: Date = .now,
        retryCount: Int = 0,
        failureCategory: ScanReconstructionFailureCategory? = nil,
        promotedSurfaceValid: Bool = false
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.scanID = scanID
        self.source = source
        self.reconstructionConfiguration = reconstructionConfiguration
        self.extractionConfiguration = extractionConfiguration
        self.stage = stage
        self.completedFrameCount = completedFrameCount
        self.totalFrameCount = totalFrameCount
        self.completedSubmapCount = completedSubmapCount
        self.totalSubmapCount = totalSubmapCount
        self.lastSafeUpdate = lastSafeUpdate
        self.retryCount = retryCount
        self.failureCategory = failureCategory
        self.promotedSurfaceValid = promotedSurfaceValid
    }
}

public enum ScanReconstructionThermalPressure: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct ScanReconstructionResourceSnapshot: Equatable, Sendable {
    public var availableStorageBytes: Int64?
    public var thermalPressure: ScanReconstructionThermalPressure
    public var isLowPowerModeEnabled: Bool

    public init(
        availableStorageBytes: Int64?,
        thermalPressure: ScanReconstructionThermalPressure,
        isLowPowerModeEnabled: Bool
    ) {
        self.availableStorageBytes = availableStorageBytes
        self.thermalPressure = thermalPressure
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public protocol ScanReconstructionResourceMonitoring: Sendable {
    func snapshot() async -> ScanReconstructionResourceSnapshot
}

public struct SystemScanReconstructionResourceMonitor: ScanReconstructionResourceMonitoring {
    private let volumeURL: URL

    public init(volumeURL: URL) {
        self.volumeURL = volumeURL
    }

    public func snapshot() async -> ScanReconstructionResourceSnapshot {
        let capacity = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        let thermal: ScanReconstructionThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            thermal = .nominal
        case .fair:
            thermal = .fair
        case .serious:
            thermal = .serious
        case .critical:
            thermal = .critical
        @unknown default:
            thermal = .unknown
        }
        return ScanReconstructionResourceSnapshot(
            availableStorageBytes: capacity,
            thermalPressure: thermal,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

public enum ScanReconstructionJobEvent: Equatable, Sendable {
    case verifyingSource
    case sourceVerified(TSDFReconstructionSource)
    case reconstructing(TSDFReconstructionProgress)
    case extracting(TSDFSurfaceExtractionProgress)
}

public enum ScanReconstructionJobError: Error, Equatable, Sendable {
    case unavailable(ScanReconstructionFailureCategory)
    case paused(ScanReconstructionFailureCategory)
    case retryable(ScanReconstructionFailureCategory)
    case terminal(ScanReconstructionFailureCategory)
}

public protocol ScanReconstructionJobRunning: Sendable {
    func run(
        scanID: UUID,
        event: @escaping @Sendable (ScanReconstructionJobEvent) async throws -> Void
    ) async throws -> TSDFReconstructionSource
}

public struct LocalScanReconstructionRunner: ScanReconstructionJobRunning {
    private let repository: LocalScanRepository
    private let assetStore: FileAssetStore
    private let processedSurfaceStore: ProcessedSurfaceStore
    private let processingRootURL: URL
    private let derivedRootURL: URL
    private let reconstructionConfiguration: TSDFReconstructionConfiguration
    private let extractionConfiguration: TSDFSurfaceExtractionConfiguration

    public init(
        repository: LocalScanRepository,
        assetStore: FileAssetStore,
        processedSurfaceStore: ProcessedSurfaceStore,
        processingRootURL: URL,
        derivedRootURL: URL,
        reconstructionConfiguration: TSDFReconstructionConfiguration = .productionBalanced,
        extractionConfiguration: TSDFSurfaceExtractionConfiguration = .default
    ) {
        self.repository = repository
        self.assetStore = assetStore
        self.processedSurfaceStore = processedSurfaceStore
        self.processingRootURL = processingRootURL
        self.derivedRootURL = derivedRootURL
        self.reconstructionConfiguration = reconstructionConfiguration
        self.extractionConfiguration = extractionConfiguration
    }

    public func run(
        scanID: UUID,
        event: @escaping @Sendable (ScanReconstructionJobEvent) async throws -> Void
    ) async throws -> TSDFReconstructionSource {
        try await event(.verifyingSource)
        try validateManagedDirectory(
            root: processingRootURL,
            scanID: scanID
        )
        try validateManagedDirectory(
            root: derivedRootURL,
            scanID: scanID
        )
        guard let stored = try await repository.reopen(id: scanID) else {
            throw ScanReconstructionJobError.unavailable(.unsupportedLegacyPackage)
        }
        guard stored.integrity.isValid else {
            throw ScanReconstructionJobError.terminal(.invalidPackageIntegrity)
        }
        let packageURL = try await assetStore.packageURL(for: scanID)
        let archive: CalibratedRGBDKeyframeReplayArchive
        do {
            archive = try CalibratedRGBDKeyframeArchiveReader().open(
                packageURL: packageURL,
                manifest: stored.manifest,
                integrity: stored.integrity
            )
        } catch CalibratedRGBDKeyframeArchiveError.indexMissing {
            throw ScanReconstructionJobError.unavailable(.missingArchive)
        } catch CalibratedRGBDKeyframeArchiveError.ioFailure {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        } catch {
            throw ScanReconstructionJobError.terminal(.invalidArchive)
        }
        let source = archive.reconstructionSource
        guard source.keyframeCount > 0 else {
            throw ScanReconstructionJobError.unavailable(.missingArchive)
        }
        try await event(.sourceVerified(source))

        if let promoted = try? await processedSurfaceStore.validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: stored.manifest,
            integrity: stored.integrity
        ), promoted.manifest.prefix.configuration == reconstructionConfiguration,
           promoted.manifest.extractionConfiguration == extractionConfiguration {
            return source
        }

        let canonical: CanonicalSpatialChunkDescriptor
        do {
            canonical = try CanonicalSpatialChunkReader().open(
                packageURL: packageURL,
                manifest: stored.manifest,
                integrity: stored.integrity
            )
        } catch CanonicalSpatialChunkReadError.missingSource {
            throw ScanReconstructionJobError.unavailable(.unsupportedLegacyPackage)
        } catch {
            throw ScanReconstructionJobError.terminal(.sourceIdentityMismatch)
        }
        let canonicalBounds = try TSDFSurfaceBounds(
            minimum: canonical.bounds.minimum,
            maximum: canonical.bounds.maximum
        )
        let scanProcessingURL = processingRootURL.appending(
            path: scanID.uuidString,
            directoryHint: .isDirectory
        )
        let reconstructionURL = scanProcessingURL.appending(
            path: "tsdf",
            directoryHint: .isDirectory
        )
        let extractionURL = scanProcessingURL.appending(
            path: "surface-extraction",
            directoryHint: .isDirectory
        )
        let promotionURL = derivedRootURL
            .appending(path: scanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "processed-surface", directoryHint: .isDirectory)

        let state: TSDFReconstructionState
        do {
            state = try await CalibratedRGBDTSDFPipeline().run(
                packageURL: packageURL,
                manifest: stored.manifest,
                integrity: stored.integrity,
                outputDirectory: reconstructionURL,
                configuration: reconstructionConfiguration
            ) { progress in
                try await event(.reconstructing(progress))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch TSDFReconstructionError.invalidOutputLocation {
            throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
        } catch TSDFReconstructionError.sourceMismatch,
                TSDFReconstructionError.configurationMismatch {
            throw ScanReconstructionJobError.terminal(.sourceIdentityMismatch)
        } catch TSDFReconstructionError.invalidFile {
            throw ScanReconstructionJobError.terminal(.invalidArchive)
        } catch {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        }
        guard state.nextFrameIndex == source.keyframeCount + 1 else {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        }

        let reconstructor: ChunkedTSDFReconstructor
        do {
            reconstructor = try ChunkedTSDFReconstructor(
                outputDirectory: reconstructionURL,
                source: source,
                configuration: reconstructionConfiguration
            )
        } catch TSDFReconstructionError.sourceMismatch,
                TSDFReconstructionError.configurationMismatch {
            throw ScanReconstructionJobError.terminal(.sourceIdentityMismatch)
        } catch {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        }
        let result: TSDFSurfaceExtractionResult
        do {
            result = try await TSDFSurfaceExtractionPipeline().run(
                source: reconstructor,
                sourcePackageURL: packageURL,
                stagingDirectory: extractionURL,
                promotionDirectory: promotionURL,
                canonicalSpatialBounds: canonicalBounds,
                configuration: extractionConfiguration
            ) { progress in
                try await event(.extracting(progress))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch TSDFSurfaceExtractionError.invalidWritableLocation {
            throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
        } catch TSDFSurfaceExtractionError.promotionConflict {
            throw ScanReconstructionJobError.terminal(.promotionConflict)
        } catch TSDFSurfaceExtractionError.snapshotMismatch,
                TSDFSurfaceExtractionError.invalidStagingArtifact {
            throw ScanReconstructionJobError.terminal(.sourceIdentityMismatch)
        } catch {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        }
        guard result.validation.isValid,
              result.promotedDirectory == promotionURL,
              result.manifest != nil
        else {
            throw ScanReconstructionJobError.terminal(.surfaceValidation)
        }
        do {
            _ = try await processedSurfaceStore.loadProcessedSurface(
                scanID: scanID,
                packageURL: packageURL,
                manifest: stored.manifest,
                integrity: stored.integrity
            )
        } catch {
            throw ScanReconstructionJobError.terminal(.surfaceValidation)
        }
        return source
    }

    private func validateManagedDirectory(
        root: URL,
        scanID: UUID
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
            }
        } else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let directory = root.appending(path: scanID.uuidString, directoryHint: .isDirectory)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/") else {
            throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
        }
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
            }
        }
        var pendingDirectories = fileManager.fileExists(atPath: directory.path) ? [directory] : []
        while let current = pendingDirectories.popLast() {
            let children = try fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let path = child.resolvingSymlinksInPath().standardizedFileURL.path
                guard values.isSymbolicLink != true,
                      path.hasPrefix(rootPath + "/")
                else {
                    throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
                }
                if values.isDirectory == true {
                    pendingDirectories.append(child)
                }
            }
        }
    }
}

public actor ScanReconstructionCoordinator {
    public static let provisionalMinimumAvailableStorageBytes: Int64 = 1_073_741_824

    private static let stateFilename = "coordinator-state.json"

    private let runner: any ScanReconstructionJobRunning
    private let resourceMonitor: any ScanReconstructionResourceMonitoring
    private let processingRootURL: URL
    private let reconstructionConfiguration: TSDFReconstructionConfiguration
    private let extractionConfiguration: TSDFSurfaceExtractionConfiguration
    private let minimumAvailableStorageBytes: Int64
    private let now: @Sendable () -> Date
    private var statuses: [UUID: ScanReconstructionStatus] = [:]
    private var queue: [UUID] = []
    private var activeJob: (scanID: UUID, task: Task<Void, Never>)?
    private var subscribers: [UUID: [UUID: AsyncStream<ScanReconstructionStatus>.Continuation]] = [:]
    private var applicationActive = true
    private var lifecyclePauseRequests: Set<UUID> = []
    private var jobsStarted = 0

    public init(
        runner: any ScanReconstructionJobRunning,
        resourceMonitor: any ScanReconstructionResourceMonitoring,
        processingRootURL: URL,
        reconstructionConfiguration: TSDFReconstructionConfiguration = .productionBalanced,
        extractionConfiguration: TSDFSurfaceExtractionConfiguration = .default,
        minimumAvailableStorageBytes: Int64 = provisionalMinimumAvailableStorageBytes,
        now: @escaping @Sendable () -> Date = { .now },
        fileManager: FileManager = .default
    ) throws {
        guard minimumAvailableStorageBytes > 0 else {
            throw ScanReconstructionJobError.terminal(.insufficientStorage)
        }
        if fileManager.fileExists(atPath: processingRootURL.path) {
            let values = try processingRootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
            }
        } else {
            try fileManager.createDirectory(at: processingRootURL, withIntermediateDirectories: true)
        }
        self.runner = runner
        self.resourceMonitor = resourceMonitor
        self.processingRootURL = processingRootURL
        self.reconstructionConfiguration = reconstructionConfiguration
        self.extractionConfiguration = extractionConfiguration
        self.minimumAvailableStorageBytes = minimumAvailableStorageBytes
        self.now = now
    }

    @discardableResult
    public func enqueue(scanID: UUID, automatic: Bool = true) -> ScanReconstructionStatus {
        var status = statusForScan(scanID)
        if activeJob?.scanID == scanID || queue.contains(scanID) {
            return status
        }
        if automatic {
            switch status.stage {
            case .ready, .unavailable, .failedRetryable, .failedTerminal:
                return status
            default:
                break
            }
        }
        status.stage = .queued
        status.failureCategory = nil
        status.lastSafeUpdate = now()
        do {
            try persistAndPublish(status)
        } catch {
            return publishPersistenceFailure(for: status, error: error)
        }
        queue.append(scanID)
        startNextIfPossible()
        return status
    }

    public func retry(scanID: UUID) -> ScanReconstructionStatus {
        var status = statusForScan(scanID)
        guard status.stage == .failedRetryable || status.stage == .paused else {
            return status
        }
        status.retryCount += 1
        status.stage = .queued
        status.failureCategory = nil
        status.lastSafeUpdate = now()
        do {
            try persistAndPublish(status)
        } catch {
            return publishPersistenceFailure(for: status, error: error)
        }
        if activeJob?.scanID != scanID, !queue.contains(scanID) {
            queue.append(scanID)
        }
        startNextIfPossible()
        return status
    }

    public func status(scanID: UUID) -> ScanReconstructionStatus {
        statusForScan(scanID)
    }

    public func updates(scanID: UUID) -> AsyncStream<ScanReconstructionStatus> {
        let subscriberID = UUID()
        let initial = statusForScan(scanID)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[scanID, default: [:]][subscriberID] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID, scanID: scanID) }
            }
        }
    }

    public func setApplicationActive(_ isActive: Bool) async {
        applicationActive = isActive
        if !isActive, let activeJob {
            lifecyclePauseRequests.insert(activeJob.scanID)
            activeJob.task.cancel()
            await activeJob.task.value
        } else if isActive {
            resumePausedJobs()
            startNextIfPossible()
        }
    }

    public func resumePendingJobs() {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: processingRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let scanID = UUID(uuidString: directory.lastPathComponent),
                  let status = loadStatus(scanID: scanID)
            else { continue }
            statuses[scanID] = status
            switch status.stage {
            case .queued, .verifyingSource, .reconstructing, .extractingSurface,
                    .validatingSurface, .promotingSurface, .paused:
                if !queue.contains(scanID), activeJob?.scanID != scanID {
                    queue.append(scanID)
                }
            case .ready, .unavailable, .failedRetryable, .failedTerminal:
                break
            }
        }
        startNextIfPossible()
    }

    public func cancelAndWait(scanID: UUID) async {
        queue.removeAll { $0 == scanID }
        if let activeJob, activeJob.scanID == scanID {
            activeJob.task.cancel()
            await activeJob.task.value
        }
        statuses.removeValue(forKey: scanID)
        subscribers.removeValue(forKey: scanID)?.values.forEach { $0.finish() }
    }

    public func startedJobCount() -> Int { jobsStarted }

    private func startNextIfPossible() {
        guard applicationActive, activeJob == nil, !queue.isEmpty else { return }
        let scanID = queue.removeFirst()
        jobsStarted += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performJob(scanID: scanID)
        }
        activeJob = (scanID, task)
    }

    private func performJob(scanID: UUID) async {
        var shouldResumeAfterLifecyclePause = false
        do {
            try await requireExecutionAvailable()
            let source = try await runner.run(scanID: scanID) { [weak self] event in
                guard let self else { throw CancellationError() }
                try await self.handle(event, scanID: scanID)
            }
            var status = statusForScan(scanID)
            status.source = source
            status.stage = .ready
            status.completedFrameCount = source.keyframeCount
            status.totalFrameCount = source.keyframeCount
            status.failureCategory = nil
            status.promotedSurfaceValid = true
            status.lastSafeUpdate = now()
            do {
                try persistAndPublish(status)
            } catch {
                _ = publishPersistenceFailure(for: status, error: error)
            }
        } catch is CancellationError {
            var status = statusForScan(scanID)
            let lifecyclePause = lifecyclePauseRequests.remove(scanID) != nil
            status.stage = lifecyclePause ? .paused : .failedRetryable
            status.failureCategory = lifecyclePause ? .applicationInactive : .cancelled
            shouldResumeAfterLifecyclePause = lifecyclePause && applicationActive
            status.lastSafeUpdate = now()
            do {
                try persistAndPublish(status)
            } catch {
                _ = publishPersistenceFailure(for: status, error: error)
            }
        } catch let error as ScanReconstructionJobError {
            var status = statusForScan(scanID)
            switch error {
            case let .unavailable(category):
                status.stage = .unavailable
                status.failureCategory = category
            case let .paused(category):
                status.stage = .paused
                status.failureCategory = category
            case let .retryable(category):
                status.stage = .failedRetryable
                status.failureCategory = category
            case let .terminal(category):
                status.stage = .failedTerminal
                status.failureCategory = category
            }
            status.lastSafeUpdate = now()
            do {
                try persistAndPublish(status)
            } catch {
                _ = publishPersistenceFailure(for: status, error: error)
            }
        } catch {
            var status = statusForScan(scanID)
            status.stage = .failedRetryable
            status.failureCategory = .interruptedIO
            status.lastSafeUpdate = now()
            do {
                try persistAndPublish(status)
            } catch {
                _ = publishPersistenceFailure(for: status, error: error)
            }
        }
        if activeJob?.scanID == scanID {
            activeJob = nil
        }
        lifecyclePauseRequests.remove(scanID)
        if shouldResumeAfterLifecyclePause,
           !queue.contains(scanID) {
            queue.append(scanID)
        }
        startNextIfPossible()
    }

    private func handle(_ event: ScanReconstructionJobEvent, scanID: UUID) async throws {
        try Task.checkCancellation()
        try await requireExecutionAvailable()
        var status = statusForScan(scanID)
        switch event {
        case .verifyingSource:
            status.stage = .verifyingSource
        case let .sourceVerified(source):
            status.source = source
            status.totalFrameCount = source.keyframeCount
        case let .reconstructing(progress):
            status.stage = .reconstructing
            status.completedFrameCount = progress.completedFrameCount
            status.totalFrameCount = progress.totalFrameCount
        case let .extracting(progress):
            switch progress.phase {
            case .extracting:
                status.stage = .extractingSurface
            case .validating:
                status.stage = .validatingSurface
            case .promoting:
                status.stage = .promotingSurface
            }
            status.completedSubmapCount = progress.completedSubmapCount
            status.totalSubmapCount = progress.totalSubmapCount
        }
        status.lastSafeUpdate = now()
        do {
            try persistAndPublish(status)
        } catch let error as ScanReconstructionJobError {
            throw error
        } catch {
            throw ScanReconstructionJobError.retryable(.interruptedIO)
        }
    }

    private func requireExecutionAvailable() async throws {
        guard applicationActive else { throw CancellationError() }
        let resources = await resourceMonitor.snapshot()
        guard let available = resources.availableStorageBytes,
              available >= minimumAvailableStorageBytes
        else {
            throw ScanReconstructionJobError.paused(.insufficientStorage)
        }
        guard resources.thermalPressure != .serious,
              resources.thermalPressure != .critical
        else {
            throw ScanReconstructionJobError.paused(.thermalPressure)
        }
        guard !resources.isLowPowerModeEnabled else {
            throw ScanReconstructionJobError.paused(.lowPower)
        }
    }

    private func resumePausedJobs() {
        for (scanID, status) in statuses where status.stage == .paused {
            if !queue.contains(scanID), activeJob?.scanID != scanID {
                queue.append(scanID)
            }
        }
    }

    private func statusForScan(_ scanID: UUID) -> ScanReconstructionStatus {
        if let status = statuses[scanID] { return status }
        if let status = loadStatus(scanID: scanID) {
            statuses[scanID] = status
            return status
        }
        let status = ScanReconstructionStatus(
            scanID: scanID,
            reconstructionConfiguration: reconstructionConfiguration,
            extractionConfiguration: extractionConfiguration,
            lastSafeUpdate: now()
        )
        statuses[scanID] = status
        return status
    }

    private func persistAndPublish(_ status: ScanReconstructionStatus) throws {
        statuses[status.scanID] = status
        let url = try safeStateURL(scanID: status.scanID, createDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(status).write(to: url, options: .atomic)
        subscribers[status.scanID]?.values.forEach { $0.yield(status) }
    }

    private func publishPersistenceFailure(
        for status: ScanReconstructionStatus,
        error: Error
    ) -> ScanReconstructionStatus {
        var failed = status
        if case ScanReconstructionJobError.terminal(.invalidDerivedPath) = error {
            failed.stage = .failedTerminal
            failed.failureCategory = .invalidDerivedPath
        } else {
            failed.stage = .failedRetryable
            failed.failureCategory = .interruptedIO
        }
        failed.promotedSurfaceValid = false
        failed.lastSafeUpdate = now()
        statuses[failed.scanID] = failed
        subscribers[failed.scanID]?.values.forEach { $0.yield(failed) }
        return failed
    }

    private func loadStatus(scanID: UUID) -> ScanReconstructionStatus? {
        guard let url = try? safeStateURL(scanID: scanID, createDirectory: false),
              let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(ScanReconstructionStatus.self, from: data),
              status.schemaVersion == ScanReconstructionStatus.currentSchemaVersion,
              status.scanID == scanID,
              status.reconstructionConfiguration == reconstructionConfiguration,
              status.extractionConfiguration == extractionConfiguration
        else { return nil }
        return status
    }

    private func safeStateURL(scanID: UUID, createDirectory: Bool) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: processingRootURL.path) else {
            if createDirectory {
                try fileManager.createDirectory(at: processingRootURL, withIntermediateDirectories: true)
            } else {
                throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
            }
            return try safeStateURL(scanID: scanID, createDirectory: createDirectory)
        }
        let rootValues = try processingRootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
        }

        let directory = processingRootURL.appending(
            path: scanID.uuidString,
            directoryHint: .isDirectory
        )
        let existingValues = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        if !fileManager.fileExists(atPath: directory.path), existingValues?.isSymbolicLink != true {
            guard createDirectory else {
                throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let rootPath = processingRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              directoryPath.hasPrefix(rootPath + "/")
        else {
            throw ScanReconstructionJobError.terminal(.invalidDerivedPath)
        }
        return directory.appending(path: Self.stateFilename)
    }

    private func removeSubscriber(_ subscriberID: UUID, scanID: UUID) {
        subscribers[scanID]?.removeValue(forKey: subscriberID)
        if subscribers[scanID]?.isEmpty == true { subscribers.removeValue(forKey: scanID) }
    }
}
