import Foundation

public enum ScanFailureReason: String, Codable, CaseIterable, Sendable {
    case unsupportedDevice
    case permissionDenied
    case sensorUnavailable
    case interrupted
    case noSpatialData
    case processingFailed
    case saveFailed
    case corruptedAsset
    case unknown
}

public enum ScanLifecycleState: Codable, Equatable, Sendable {
    case idle
    case preparing
    case capabilityChecking
    case requestingPermissions
    case ready
    case scanning
    case pausing
    case processing
    case saving
    case completed
    case failed(ScanFailureReason)
    case cancelled
    case recovering
    case insufficientStorage
    case trackingLost

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        default:
            false
        }
    }
}

public enum ScanLifecycleEvent: Codable, Equatable, Sendable {
    case begin
    case preparationComplete
    case capabilitiesAvailable
    case capabilitiesUnavailable
    case permissionsGranted
    case permissionsDenied
    case scanStarted
    case pauseRequested
    case resumeRequested
    case scanFinished
    case processingFinished
    case saveSucceeded
    case fail(ScanFailureReason)
    case cancel
    case recover
    case recoveryFinished
    case storageInsufficient
    case storageAvailable
    case trackingDegraded
    case trackingRecovered
}

public enum ScanLifecycleError: Error, Equatable, Sendable {
    case invalidTransition(from: ScanLifecycleState, event: ScanLifecycleEvent)
}

/// The state machine is deliberately synchronous and side-effect free. Platform
/// adapters perform work, then feed their observable result back as an event.
public struct ScanLifecycleMachine: Sendable, Equatable {
    public private(set) var state: ScanLifecycleState

    public init(state: ScanLifecycleState = .idle) {
        self.state = state
    }

    public mutating func send(_ event: ScanLifecycleEvent) throws {
        guard let nextState = transition(for: event) else {
            throw ScanLifecycleError.invalidTransition(from: state, event: event)
        }
        state = nextState
    }

    private func transition(for event: ScanLifecycleEvent) -> ScanLifecycleState? {
        if event == .cancel, !state.isTerminal {
            return .cancelled
        }

        if case let .fail(reason) = event, !state.isTerminal {
            return .failed(reason)
        }

        return switch (state, event) {
        case (.idle, .begin), (.completed, .begin), (.cancelled, .begin):
            .preparing
        case (.preparing, .preparationComplete):
            .capabilityChecking
        case (.capabilityChecking, .capabilitiesAvailable):
            .requestingPermissions
        case (.capabilityChecking, .capabilitiesUnavailable):
            .failed(.unsupportedDevice)
        case (.requestingPermissions, .permissionsGranted):
            .ready
        case (.requestingPermissions, .permissionsDenied):
            .failed(.permissionDenied)
        case (.ready, .scanStarted):
            .scanning
        case (.scanning, .pauseRequested):
            .pausing
        case (.pausing, .resumeRequested):
            .scanning
        case (.scanning, .scanFinished):
            .processing
        case (.processing, .processingFinished):
            .saving
        case (.saving, .saveSucceeded):
            .completed
        case (.scanning, .trackingDegraded):
            .trackingLost
        case (.trackingLost, .trackingRecovered):
            .scanning
        case (.scanning, .storageInsufficient), (.processing, .storageInsufficient), (.saving, .storageInsufficient):
            .insufficientStorage
        case (.insufficientStorage, .storageAvailable):
            .ready
        case (.failed, .recover):
            .recovering
        case (.recovering, .recoveryFinished):
            .idle
        default:
            nil
        }
    }
}
