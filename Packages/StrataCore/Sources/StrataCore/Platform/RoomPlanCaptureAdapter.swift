#if os(iOS) && canImport(RoomPlan)
@preconcurrency import RoomPlan
import CoreGraphics
import Foundation

public struct SemanticRoomSummary: Equatable, Sendable {
    public var wallCount: Int
    public var doorCount: Int
    public var windowCount: Int
    public var objectCount: Int

    public init(wallCount: Int, doorCount: Int, windowCount: Int, objectCount: Int) {
        self.wallCount = wallCount
        self.doorCount = doorCount
        self.windowCount = windowCount
        self.objectCount = objectCount
    }
}

public enum RoomPlanCaptureEvent: Sendable {
    case roomUpdated(SemanticRoomSummary)
    case finished
    case failed(String)
}

public enum RoomPlanCaptureAdapterError: Error, Equatable, Sendable {
    case unsupportedDevice
    case noCapturedRoomData
    case processingFailed(String)
    case exportFailed(String)
}

/// Owns a RoomPlan session independently from raw ARKit capture. Composition
/// selects one mode per scan attempt, avoiding two owners for the same ARSession.
@MainActor
public final class RoomPlanCaptureAdapter: NSObject, RoomCaptureSessionDelegate {
    /// RoomPlan owns this view and its capture session together. It must not be
    /// represented by a separate ARSCNView, which would introduce another
    /// renderer/session owner during semantic capture.
    public let captureView: RoomCaptureView
    public let session: RoomCaptureSession
    public let events: AsyncStream<RoomPlanCaptureEvent>

    private let eventContinuation: AsyncStream<RoomPlanCaptureEvent>.Continuation
    private var capturedRoomData: CapturedRoomData?
    private var completionContinuation: CheckedContinuation<CapturedRoomData, Error>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var terminalFailure: RoomPlanCaptureAdapterError?
    private var isCapturing = false
    private var isStopping = false
    private var isFinalizing = false
    private var expectsTerminalCallback = false
    private var discardsTerminalResult = false
    private var cancellationRequested = false

    public init(captureView: RoomCaptureView = RoomCaptureView(frame: .zero)) {
        self.captureView = captureView
        self.session = captureView.captureSession
        var capturedContinuation: AsyncStream<RoomPlanCaptureEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation")
        }
        eventContinuation = capturedContinuation
        super.init()
        session.delegate = self
    }

    deinit {
        eventContinuation.finish()
    }

    public func start() throws {
        guard RoomCaptureSession.isSupported else {
            throw RoomPlanCaptureAdapterError.unsupportedDevice
        }
        guard !isCapturing, !isStopping, !isFinalizing, completionContinuation == nil else {
            throw RoomPlanCaptureAdapterError.processingFailed("A previous RoomPlan capture is still finishing.")
        }
        capturedRoomData = nil
        terminalFailure = nil
        discardsTerminalResult = false
        cancellationRequested = false
        isCapturing = true
        expectsTerminalCallback = true
        session.run(configuration: .init())
    }

    public func stop() {
        guard isCapturing, !isStopping else {
            return
        }
        isStopping = true
        session.stop(pauseARSession: true)
    }

    /// Cancels a RoomPlan attempt and waits until RoomPlan has delivered its
    /// terminal callback. Callers must keep the capture surface alive until this
    /// returns so the underlying AR session cannot outlive its presentation.
    public func cancel() async {
        guard isCapturing || isStopping || isFinalizing || completionContinuation != nil
                || capturedRoomData != nil || terminalFailure != nil
        else {
            return
        }

        let shouldWaitForTerminalCallback = isCapturing || isStopping
        let shouldRequestStop = isCapturing && !isStopping
        cancellationRequested = true
        discardsTerminalResult = true
        isCapturing = false
        capturedRoomData = nil
        terminalFailure = nil
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume(throwing: CancellationError())

        guard shouldWaitForTerminalCallback else {
            return
        }

        isStopping = true
        await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
            if shouldRequestStop {
                session.stop(pauseARSession: true)
            }
        }
    }

    /// Stops the current capture, waits for its delegate callback, then writes a
    /// semantic parametric USDZ. It does not infer a transform into raw ARKit space.
    public func finishAndExport(to url: URL) async throws {
        guard !isFinalizing else {
            throw RoomPlanCaptureAdapterError.processingFailed("RoomPlan finalization is already in progress.")
        }
        guard isCapturing || capturedRoomData != nil else {
            if let terminalFailure {
                throw terminalFailure
            }
            throw RoomPlanCaptureAdapterError.noCapturedRoomData
        }

        isFinalizing = true
        defer {
            isFinalizing = false
            capturedRoomData = nil
        }

        try ensureCaptureWasNotCancelled()
        stop()
        let roomData = try await awaitCapturedRoomData()
        try ensureCaptureWasNotCancelled()

        let room: CapturedRoom
        do {
            room = try await RoomBuilder(options: []).capturedRoom(from: roomData)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RoomPlanCaptureAdapterError.processingFailed(error.localizedDescription)
        }
        try ensureCaptureWasNotCancelled()
        try exportSemanticRoom(room, to: url)
    }

    public func exportSemanticRoom(_ room: CapturedRoom, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try room.export(to: url, exportOptions: [.parametric])
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw RoomPlanCaptureAdapterError.exportFailed("RoomPlan did not write a usable USDZ asset.")
            }
        } catch let error as RoomPlanCaptureAdapterError {
            throw error
        } catch {
            throw RoomPlanCaptureAdapterError.exportFailed(error.localizedDescription)
        }
    }

    /// RoomPlan invokes its delegate on its own serial queue, not necessarily
    /// the main actor. Keep this protocol entry point nonisolated, then move
    /// the state mutation onto the adapter's main-actor owner.
    nonisolated public func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in
            self?.handleRoomUpdate(room)
        }
    }

    /// See `captureSession(_:didUpdate:)`: RoomPlan's terminal callback also
    /// arrives on its private queue and must not synchronously enter main-actor
    /// state from that executor.
    nonisolated public func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.handleRoomEnd(data: data, error: error)
        }
    }

    private func handleRoomUpdate(_ room: CapturedRoom) {
        guard isCapturing, !isStopping, expectsTerminalCallback else {
            return
        }
        eventContinuation.yield(.roomUpdated(summary(from: room)))
    }

    private func handleRoomEnd(data: CapturedRoomData, error: (any Error)?) {
        guard expectsTerminalCallback else {
            return
        }
        expectsTerminalCallback = false
        isCapturing = false
        isStopping = false
        let terminalContinuations = stopContinuations
        stopContinuations.removeAll(keepingCapacity: false)
        for continuation in terminalContinuations {
            continuation.resume()
        }
        if discardsTerminalResult {
            discardsTerminalResult = false
            capturedRoomData = nil
            return
        }
        if let error {
            let failure = RoomPlanCaptureAdapterError.processingFailed(error.localizedDescription)
            terminalFailure = failure
            let continuation = completionContinuation
            completionContinuation = nil
            continuation?.resume(throwing: failure)
            eventContinuation.yield(.failed(error.localizedDescription))
            return
        }
        capturedRoomData = data
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume(returning: data)
        eventContinuation.yield(.finished)
    }

    private func awaitCapturedRoomData() async throws -> CapturedRoomData {
        try ensureCaptureWasNotCancelled()
        if let terminalFailure {
            throw terminalFailure
        }
        if let capturedRoomData {
            return capturedRoomData
        }
        guard completionContinuation == nil else {
            throw RoomPlanCaptureAdapterError.processingFailed("RoomPlan finalization is already in progress.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            completionContinuation = continuation
        }
    }

    private func ensureCaptureWasNotCancelled() throws {
        guard !cancellationRequested else {
            throw CancellationError()
        }
    }

    private func summary(from room: CapturedRoom) -> SemanticRoomSummary {
        SemanticRoomSummary(
            wallCount: room.walls.count,
            doorCount: room.doors.count,
            windowCount: room.windows.count,
            objectCount: room.objects.count
        )
    }
}
#endif
