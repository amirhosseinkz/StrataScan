import Foundation

public enum SyncQueueState: String, Codable, CaseIterable, Sendable {
    case pending
    case uploading
    case retryScheduled
    case succeeded
    case failed
    case conflict
    case cancelled
}

public enum SyncFailure: Codable, Equatable, Sendable {
    case offline
    case retryable(String)
    case unauthorized
    case rejected(String)
    case conflict
    case interrupted
    case unknown(String)
}

/// A durable, replay-safe upload intent. The request's idempotency key is also
/// the queue item identifier so interruption recovery never creates a new remote
/// operation by accident.
public struct SyncQueueItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var request: UploadScanRequestDTO
    public var state: SyncQueueState
    public var retryCount: Int
    public var nextAttemptAt: Date?
    public var lastFailure: SyncFailure?
    public var remoteScan: RemoteScanDTO?
    public var conflictRemoteScan: RemoteScanDTO?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID? = nil,
        request: UploadScanRequestDTO,
        state: SyncQueueState = .pending,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastFailure: SyncFailure? = nil,
        remoteScan: RemoteScanDTO? = nil,
        conflictRemoteScan: RemoteScanDTO? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id ?? request.idempotencyKey
        self.request = request
        self.state = state
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.lastFailure = lastFailure
        self.remoteScan = remoteScan
        self.conflictRemoteScan = conflictRemoteScan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var synchronizationStatus: SynchronizationStatus {
        switch state {
        case .pending, .retryScheduled:
            .pendingUpload
        case .uploading:
            .uploading
        case .succeeded:
            .synced
        case .failed:
            .failed
        case .conflict:
            .conflict
        case .cancelled:
            .localOnly
        }
    }
}

public struct SyncRetryPolicy: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var maximumRetryCount: Int

    public init(
        initialDelay: TimeInterval = 30,
        maximumDelay: TimeInterval = 3_600,
        maximumRetryCount: Int = 3
    ) {
        let normalizedInitialDelay = max(0, initialDelay)
        self.initialDelay = normalizedInitialDelay
        self.maximumDelay = max(normalizedInitialDelay, maximumDelay)
        self.maximumRetryCount = max(0, maximumRetryCount)
    }

    public func delay(forRetryCount retryCount: Int) -> TimeInterval {
        guard retryCount > 1 else { return initialDelay }

        var delay = initialDelay
        for _ in 1 ..< retryCount {
            delay = min(maximumDelay, delay * 2)
        }
        return delay
    }
}

public protocol SyncQueueStore: Sendable {
    func load() async throws -> [SyncQueueItem]
    func save(_ items: [SyncQueueItem]) async throws
}

public enum SyncQueueStoreError: Error, Equatable, Sendable {
    case unreadable
    case unwritable
}

/// A deterministic store for unit tests and for retaining state across queue
/// reconstruction within an injected test fixture.
public actor InMemorySyncQueueStore: SyncQueueStore {
    private var storedItems: [SyncQueueItem]

    public init(items: [SyncQueueItem] = []) {
        storedItems = items
    }

    public func load() async throws -> [SyncQueueItem] {
        storedItems
    }

    public func save(_ items: [SyncQueueItem]) async throws {
        storedItems = items
    }
}

/// JSON persistence is intentionally an infrastructure boundary. It keeps queue
/// records small, atomically replaces snapshots, and never stores scan binaries.
public actor FileSyncQueueStore: SyncQueueStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> [SyncQueueItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            return try RemoteAPICodec.decode([SyncQueueItem].self, from: data)
        } catch {
            throw SyncQueueStoreError.unreadable
        }
    }

    public func save(_ items: [SyncQueueItem]) async throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try RemoteAPICodec.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SyncQueueStoreError.unwritable
        }
    }
}

public enum SyncQueueError: Error, Equatable, Sendable {
    case itemNotFound(UUID)
    case cannotCancel(SyncQueueState)
    case cannotRetry(SyncQueueState)
}

public enum SyncProcessResult: Equatable, Sendable {
    case succeeded(SyncQueueItem)
    case retryScheduled(SyncQueueItem)
    case failed(SyncQueueItem)
    case conflict(SyncQueueItem)
    case cancelled(SyncQueueItem)
    case notApplied(SyncQueueItem)
}

/// Serializes queue transitions and commits every externally visible state before
/// awaiting remote work. A process interruption therefore recovers as a replay
/// of the same idempotent request rather than losing or duplicating the intent.
public actor SyncQueue {
    private let store: any SyncQueueStore
    private let remoteAPI: any RemoteScanAPI
    private let retryPolicy: SyncRetryPolicy
    private let clock: @Sendable () -> Date
    private var cachedItems: [SyncQueueItem] = []
    private var hasLoaded = false
    private var isLoading = false
    private var loadingWaiters: [CheckedContinuation<Void, Error>] = []
    private var mutationGeneration = 0
    private var isProcessing = false

    public init(
        store: any SyncQueueStore,
        remoteAPI: any RemoteScanAPI,
        retryPolicy: SyncRetryPolicy = SyncRetryPolicy(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.remoteAPI = remoteAPI
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    @discardableResult
    public func enqueue(_ request: UploadScanRequestDTO) async throws -> SyncQueueItem {
        try await ensureLoaded()
        if let existing = cachedItems.first(where: { $0.id == request.idempotencyKey }) {
            return existing
        }

        let now = clock()
        let item = SyncQueueItem(request: request, createdAt: now, updatedAt: now)
        cachedItems.append(item)
        markMutated()
        try await persistCurrentState()
        return item
    }

    public func items() async throws -> [SyncQueueItem] {
        try await ensureLoaded()
        return sorted(cachedItems)
    }

    public func item(id: UUID) async throws -> SyncQueueItem? {
        try await ensureLoaded()
        return cachedItems.first(where: { $0.id == id })
    }

    @discardableResult
    public func cancel(id: UUID) async throws -> SyncQueueItem {
        try await ensureLoaded()
        guard let index = cachedItems.firstIndex(where: { $0.id == id }) else {
            throw SyncQueueError.itemNotFound(id)
        }

        var item = cachedItems[index]
        switch item.state {
        case .succeeded:
            throw SyncQueueError.cannotCancel(item.state)
        case .cancelled:
            return item
        case .pending, .uploading, .retryScheduled, .failed, .conflict:
            item.state = .cancelled
            item.nextAttemptAt = nil
            item.lastFailure = nil
            item.updatedAt = clock()
            cachedItems[index] = item
            markMutated()
            try await persistCurrentState()
            return item
        }
    }

    @discardableResult
    public func retryNow(id: UUID) async throws -> SyncQueueItem {
        try await ensureLoaded()
        guard let index = cachedItems.firstIndex(where: { $0.id == id }) else {
            throw SyncQueueError.itemNotFound(id)
        }

        var item = cachedItems[index]
        switch item.state {
        case .retryScheduled, .failed, .conflict, .cancelled:
            item.state = .pending
            item.nextAttemptAt = nil
            item.lastFailure = nil
            item.updatedAt = clock()
            cachedItems[index] = item
            markMutated()
            try await persistCurrentState()
            return item
        case .pending, .uploading, .succeeded:
            throw SyncQueueError.cannotRetry(item.state)
        }
    }

    /// Converts persisted in-flight work into an immediately eligible replay.
    /// The original idempotency key remains unchanged because delivery may have
    /// reached the remote just before the process stopped.
    public func recoverInterruptedWork() async throws -> [SyncQueueItem] {
        try await ensureLoaded()
        let recoveredAt = clock()
        var recovered: [SyncQueueItem] = []

        for index in cachedItems.indices where cachedItems[index].state == .uploading {
            cachedItems[index].state = .pending
            cachedItems[index].nextAttemptAt = nil
            cachedItems[index].lastFailure = .interrupted
            cachedItems[index].updatedAt = recoveredAt
            recovered.append(cachedItems[index])
        }

        if !recovered.isEmpty {
            markMutated()
            try await persistCurrentState()
        }
        return sorted(recovered)
    }

    public func processNext() async throws -> SyncProcessResult? {
        guard !isProcessing else { return nil }
        isProcessing = true
        defer { isProcessing = false }

        try await ensureLoaded()
        let startedAt = clock()
        guard let index = nextEligibleIndex(in: cachedItems, at: startedAt) else { return nil }

        cachedItems[index].state = .uploading
        cachedItems[index].nextAttemptAt = nil
        cachedItems[index].updatedAt = startedAt
        let selected = cachedItems[index]
        markMutated()
        try await persistCurrentState()

        guard let current = cachedItems.first(where: { $0.id == selected.id }), current.state == .uploading else {
            guard let current = cachedItems.first(where: { $0.id == selected.id }) else {
                throw SyncQueueError.itemNotFound(selected.id)
            }
            return resultForExternallyChangedItem(current)
        }

        do {
            try Task.checkCancellation()
            let response = try await remoteAPI.upload(selected.request)
            try Task.checkCancellation()
            return try await completeSuccess(id: selected.id, response: response, at: clock())
        } catch is CancellationError {
            return try await completeRemoteError(.cancelled, id: selected.id, at: clock())
        } catch let error as RemoteAPIError {
            return try await completeRemoteError(error, id: selected.id, at: clock())
        } catch {
            return try await completeRemoteError(
                .invalidResponse(message: "An unexpected remote error occurred."),
                id: selected.id,
                at: clock()
            )
        }
    }

    private func completeSuccess(
        id: UUID,
        response: UploadScanResponseDTO,
        at completedAt: Date
    ) async throws -> SyncProcessResult {
        guard let index = cachedItems.firstIndex(where: { $0.id == id }) else {
            throw SyncQueueError.itemNotFound(id)
        }

        var item = cachedItems[index]
        guard item.state == .uploading else {
            return resultForExternallyChangedItem(item)
        }

        item.state = .succeeded
        item.remoteScan = response.scan
        item.conflictRemoteScan = nil
        item.nextAttemptAt = nil
        item.lastFailure = nil
        item.updatedAt = completedAt
        cachedItems[index] = item
        markMutated()
        try await persistCurrentState()
        return .succeeded(item)
    }

    private func completeRemoteError(
        _ error: RemoteAPIError,
        id: UUID,
        at completedAt: Date
    ) async throws -> SyncProcessResult {
        guard let index = cachedItems.firstIndex(where: { $0.id == id }) else {
            throw SyncQueueError.itemNotFound(id)
        }

        var item = cachedItems[index]
        guard item.state == .uploading else {
            return resultForExternallyChangedItem(item)
        }

        let result: SyncProcessResult
        switch error {
        case .offline:
            item.lastFailure = .offline
            result = scheduleRetryOrFail(&item, at: completedAt)
        case let .retryable(message):
            item.lastFailure = .retryable(message)
            result = scheduleRetryOrFail(&item, at: completedAt)
        case .unauthorized:
            item.state = .failed
            item.nextAttemptAt = nil
            item.lastFailure = .unauthorized
            item.updatedAt = completedAt
            result = .failed(item)
        case let .rejected(message):
            item.state = .failed
            item.nextAttemptAt = nil
            item.lastFailure = .rejected(message)
            item.updatedAt = completedAt
            result = .failed(item)
        case let .conflict(current):
            item.state = .conflict
            item.nextAttemptAt = nil
            item.lastFailure = .conflict
            item.conflictRemoteScan = current
            item.updatedAt = completedAt
            result = .conflict(item)
        case .cancelled:
            item.state = .cancelled
            item.nextAttemptAt = nil
            item.lastFailure = nil
            item.updatedAt = completedAt
            result = .cancelled(item)
        case let .invalidResponse(message):
            item.state = .failed
            item.nextAttemptAt = nil
            item.lastFailure = .unknown(message)
            item.updatedAt = completedAt
            result = .failed(item)
        }

        cachedItems[index] = item
        markMutated()
        try await persistCurrentState()
        return result
    }

    private func ensureLoaded() async throws {
        if hasLoaded {
            return
        }
        if isLoading {
            try await withCheckedThrowingContinuation { continuation in
                loadingWaiters.append(continuation)
            }
            return
        }

        isLoading = true
        do {
            cachedItems = sorted(try await store.load())
            hasLoaded = true
            isLoading = false
            let waiters = loadingWaiters
            loadingWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        } catch {
            isLoading = false
            let waiters = loadingWaiters
            loadingWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    private func markMutated() {
        mutationGeneration &+= 1
    }

    /// A later actor call may mutate local state while a store save is suspended.
    /// Re-persist the newest snapshot before returning so stale writes cannot win.
    private func persistCurrentState() async throws {
        let savedGeneration = mutationGeneration
        let snapshot = sorted(cachedItems)
        try await store.save(snapshot)
        if savedGeneration != mutationGeneration {
            try await persistCurrentState()
        }
    }

    private func scheduleRetryOrFail(_ item: inout SyncQueueItem, at completedAt: Date) -> SyncProcessResult {
        item.retryCount += 1
        item.updatedAt = completedAt

        guard item.retryCount <= retryPolicy.maximumRetryCount else {
            item.state = .failed
            item.nextAttemptAt = nil
            return .failed(item)
        }

        item.state = .retryScheduled
        item.nextAttemptAt = completedAt.addingTimeInterval(retryPolicy.delay(forRetryCount: item.retryCount))
        return .retryScheduled(item)
    }

    private func resultForExternallyChangedItem(_ item: SyncQueueItem) -> SyncProcessResult {
        item.state == .cancelled ? .cancelled(item) : .notApplied(item)
    }

    private func nextEligibleIndex(in items: [SyncQueueItem], at date: Date) -> Int? {
        let eligibleIndices = items.indices.filter { index in
            switch items[index].state {
            case .pending:
                true
            case .retryScheduled:
                (items[index].nextAttemptAt ?? Date.distantFuture) <= date
            case .uploading, .succeeded, .failed, .conflict, .cancelled:
                false
            }
        }

        return eligibleIndices.min { lhs, rhs in
            let left = items[lhs]
            let right = items[rhs]
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private func sorted(_ items: [SyncQueueItem]) -> [SyncQueueItem] {
        items.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
