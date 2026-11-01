import Foundation

/// Small, platform-independent lifecycle for the raw camera writer. Keeping
/// terminal transitions explicit prevents an end, close, and new capture from
/// operating on the same AVAssetWriter concurrently.
struct CaptureRecordingLifecycle: Sendable {
    enum State: Equatable, Sendable {
        case unconfigured
        case ready
        case capturing
        case stopped
        case finalizing
    }

    enum LifecycleError: Error, Equatable, Sendable {
        case captureAlreadyActive
        case recordingNotConfigured
        case captureNotStopped
        case finalizationInProgress
    }

    private(set) var state: State = .unconfigured

    var isCapturing: Bool {
        state == .capturing
    }

    mutating func configure() throws {
        if state == .capturing {
            throw LifecycleError.captureAlreadyActive
        }
        if state == .finalizing {
            throw LifecycleError.finalizationInProgress
        }
        state = .ready
    }

    mutating func start() throws {
        switch state {
        case .ready:
            state = .capturing
        case .capturing, .stopped, .finalizing:
            throw LifecycleError.captureAlreadyActive
        case .unconfigured:
            throw LifecycleError.recordingNotConfigured
        }
    }

    /// Returns whether the caller must stop its platform capture session and
    /// emit its terminal marker. Repeated stops are intentionally no-ops.
    mutating func stop() -> Bool {
        guard state == .capturing else {
            return false
        }
        state = .stopped
        return true
    }

    mutating func beginFinalization() throws {
        switch state {
        case .stopped:
            state = .finalizing
        case .finalizing:
            throw LifecycleError.finalizationInProgress
        case .capturing:
            throw LifecycleError.captureNotStopped
        case .unconfigured, .ready:
            throw LifecycleError.recordingNotConfigured
        }
    }

    mutating func completeFinalization() {
        guard state == .finalizing else {
            return
        }
        state = .unconfigured
    }

    mutating func cancel() {
        state = .unconfigured
    }
}
