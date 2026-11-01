import Foundation
import Testing
@testable import StrataCore

@Suite("Durable sync queue", .serialized)
struct SyncQueueTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A successful upload records the remote identity and revision")
    func completesSuccessfulUpload() async throws {
        let request = makeRequest()
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI(outcomes: [
            .success(remoteID: "scan-remote-1", revision: "4", wasCreated: true)
        ])
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })

        let queued = try await queue.enqueue(request)
        _ = try await queue.processNext()
        let completed = try await queue.item(id: queued.id)

        #expect(completed?.state == .succeeded)
        #expect(completed?.remoteScan?.id == "scan-remote-1")
        #expect(completed?.remoteScan?.revision == "4")
        #expect(completed?.synchronizationStatus == .synced)
        #expect(completed?.lastFailure == nil)
    }

    @Test("Offline work is retried at a deterministic future time")
    func schedulesRetryWhenOffline() async throws {
        let request = makeRequest()
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI(outcomes: [.offline])
        let policy = SyncRetryPolicy(initialDelay: 30, maximumDelay: 120, maximumRetryCount: 3)
        let queue = SyncQueue(store: store, remoteAPI: remote, retryPolicy: policy, clock: { now })

        let queued = try await queue.enqueue(request)
        _ = try await queue.processNext()
        let retried = try await queue.item(id: queued.id)

        #expect(retried?.state == .retryScheduled)
        #expect(retried?.retryCount == 1)
        #expect(retried?.nextAttemptAt == now.addingTimeInterval(30))
        #expect(retried?.lastFailure == .offline)
        #expect(retried?.request == request)
    }

    @Test("Retrying work reuses the durable idempotent request")
    func retriesAndEventuallySucceeds() async throws {
        let request = makeRequest()
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI(outcomes: [
            .offline,
            .success(remoteID: "scan-remote-retried", revision: "2", wasCreated: true)
        ])
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })

        let queued = try await queue.enqueue(request)
        _ = try await queue.processNext()
        _ = try await queue.retryNow(id: queued.id)
        _ = try await queue.processNext()
        let completed = try await queue.item(id: queued.id)
        let receivedRequests = await remote.uploadRequests()

        #expect(completed?.state == .succeeded)
        #expect(completed?.retryCount == 1)
        #expect(completed?.remoteScan?.revision == "2")
        #expect(receivedRequests == [request, request])
    }

    @Test("A rejected upload becomes a terminal failure")
    func recordsTerminalFailure() async throws {
        let request = makeRequest()
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI(outcomes: [.rejected(message: "Checksum is invalid.")])
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })

        let queued = try await queue.enqueue(request)
        _ = try await queue.processNext()
        let failed = try await queue.item(id: queued.id)

        #expect(failed?.state == .failed)
        #expect(failed?.lastFailure == .rejected("Checksum is invalid."))
        #expect(failed?.synchronizationStatus == .failed)
    }

    @Test("A conflict preserves the current remote version for resolution")
    func recordsConflict() async throws {
        let request = makeRequest(remoteScanID: "scan-remote-2", expectedRevision: "1")
        let currentRemote = RemoteScanDTO(
            id: "scan-remote-2",
            localScanID: request.localScanID,
            displayName: "Updated by another device",
            checksumSHA256: "beef",
            revision: "2",
            updatedAt: now
        )
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI(outcomes: [.conflict(current: currentRemote)])
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })

        let queued = try await queue.enqueue(request)
        _ = try await queue.processNext()
        let conflict = try await queue.item(id: queued.id)

        #expect(conflict?.state == .conflict)
        #expect(conflict?.conflictRemoteScan == currentRemote)
        #expect(conflict?.lastFailure == .conflict)
        #expect(conflict?.synchronizationStatus == .conflict)
    }

    @Test("Cancellation prevents pending work from reaching the remote")
    func cancelsPendingWork() async throws {
        let request = makeRequest()
        let store = InMemorySyncQueueStore()
        let remote = MockRemoteScanAPI()
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })

        let queued = try await queue.enqueue(request)
        let cancelled = try await queue.cancel(id: queued.id)
        let result = try await queue.processNext()
        let receivedRequests = await remote.uploadRequests()

        #expect(cancelled.state == .cancelled)
        #expect(result == nil)
        #expect(receivedRequests.isEmpty)
    }

    @Test("Cancellation remains terminal when an active upload completes")
    func cancellationWinsOverActiveUploadCompletion() async throws {
        let request = makeRequest()
        let remote = SuspendedRemote()
        let queue = SyncQueue(store: InMemorySyncQueueStore(), remoteAPI: remote, clock: { now })
        let queued = try await queue.enqueue(request)
        let processing = Task {
            try await queue.processNext()
        }

        await remote.waitForUpload()
        _ = try await queue.cancel(id: queued.id)
        await remote.succeed(
            with: UploadScanResponseDTO(
                scan: RemoteScanDTO(
                    id: "scan-completed-after-cancel",
                    localScanID: request.localScanID,
                    displayName: request.displayName,
                    checksumSHA256: request.checksumSHA256,
                    revision: "1",
                    updatedAt: now
                ),
                wasCreated: true
            )
        )
        let result = try await processing.value
        let item = try await queue.item(id: queued.id)

        #expect(result != nil)
        #expect(item?.state == .cancelled)
        #expect(item?.remoteScan == nil)
    }

    @Test("Cancellation is not overwritten by an in-flight persistence save")
    func cancellationWinsDuringPersistenceInterleaving() async throws {
        let request = makeRequest()
        let store = SuspendingStore()
        let remote = MockRemoteScanAPI()
        let queue = SyncQueue(store: store, remoteAPI: remote, clock: { now })
        let queued = try await queue.enqueue(request)
        await store.suspendNextSave()
        let processing = Task {
            try await queue.processNext()
        }

        await store.waitForSuspendedSave()
        _ = try await queue.cancel(id: queued.id)
        await store.resumeSuspendedSave()
        _ = try await processing.value
        let item = try await queue.item(id: queued.id)
        let receivedRequests = await remote.uploadRequests()

        #expect(item?.state == .cancelled)
        #expect(receivedRequests.isEmpty)
    }

    @Test("Recovery requeues work persisted in an interrupted uploading state")
    func recoversInterruptedUpload() async throws {
        let request = makeRequest()
        let interrupted = SyncQueueItem(
            request: request,
            state: .uploading,
            retryCount: 2,
            createdAt: now,
            updatedAt: now
        )
        let store = InMemorySyncQueueStore(items: [interrupted])
        let queue = SyncQueue(store: store, remoteAPI: MockRemoteScanAPI(), clock: { now })

        let recovered = try await queue.recoverInterruptedWork()
        let item = try await queue.item(id: interrupted.id)

        #expect(recovered == [item].compactMap { $0 })
        #expect(item?.state == .pending)
        #expect(item?.retryCount == 2)
        #expect(item?.lastFailure == .interrupted)
        #expect(item?.nextAttemptAt == nil)
    }

    @Test("A file-backed queue survives reconstruction")
    func persistsPendingWorkToDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = makeRequest()
        let fileURL = root.appending(path: "sync-queue.json")
        let firstQueue = SyncQueue(
            store: FileSyncQueueStore(fileURL: fileURL),
            remoteAPI: MockRemoteScanAPI(),
            clock: { now }
        )

        let queued = try await firstQueue.enqueue(request)
        let reconstructedQueue = SyncQueue(
            store: FileSyncQueueStore(fileURL: fileURL),
            remoteAPI: MockRemoteScanAPI(),
            clock: { now }
        )
        let reloaded = try await reconstructedQueue.item(id: queued.id)

        #expect(reloaded == queued)
    }

    private func makeRequest(
        remoteScanID: String? = nil,
        expectedRevision: String? = nil
    ) -> UploadScanRequestDTO {
        UploadScanRequestDTO(
            idempotencyKey: UUID(),
            localScanID: UUID(),
            remoteScanID: remoteScanID,
            displayName: "West stairwell",
            checksumSHA256: "0123456789abcdef",
            expectedRevision: expectedRevision,
            updatedAt: now
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "StrataScanSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor SuspendedRemote: RemoteScanAPI {
    private var uploadContinuation: CheckedContinuation<UploadScanResponseDTO, Error>?
    private var uploadObserved = false
    private var uploadWaiters: [CheckedContinuation<Void, Never>] = []

    func upload(_ request: UploadScanRequestDTO) async throws -> UploadScanResponseDTO {
        uploadObserved = true
        let waiters = uploadWaiters
        uploadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        return try await withCheckedThrowingContinuation { continuation in
            uploadContinuation = continuation
        }
    }

    func waitForUpload() async {
        guard !uploadObserved else { return }
        await withCheckedContinuation { continuation in
            uploadWaiters.append(continuation)
        }
    }

    func succeed(with response: UploadScanResponseDTO) {
        guard let uploadContinuation else { return }
        self.uploadContinuation = nil
        uploadContinuation.resume(returning: response)
    }
}

private actor SuspendingStore: SyncQueueStore {
    private var items: [SyncQueueItem] = []
    private var shouldSuspendNextSave = false
    private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?
    private var saveObserved = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async throws -> [SyncQueueItem] {
        items
    }

    func save(_ items: [SyncQueueItem]) async throws {
        if shouldSuspendNextSave {
            shouldSuspendNextSave = false
            saveObserved = true
            let waiters = saveWaiters
            saveWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                suspendedSaveContinuation = continuation
            }
        }
        self.items = items
    }

    func suspendNextSave() {
        shouldSuspendNextSave = true
        saveObserved = false
    }

    func waitForSuspendedSave() async {
        guard !saveObserved else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
        }
    }

    func resumeSuspendedSave() {
        guard let suspendedSaveContinuation else { return }
        self.suspendedSaveContinuation = nil
        suspendedSaveContinuation.resume()
    }
}
