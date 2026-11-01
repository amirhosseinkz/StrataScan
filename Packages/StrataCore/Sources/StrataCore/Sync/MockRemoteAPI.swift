import Foundation

public enum MockRemoteOutcome: Equatable, Sendable {
    case success(remoteID: String, revision: String, wasCreated: Bool)
    case offline
    case retryable(message: String)
    case rejected(message: String)
    case conflict(current: RemoteScanDTO?)
    case cancelled
}

/// Deterministic test and Mock-configuration remote. Its behavior is supplied
/// explicitly, never inferred from production configuration or request values.
public actor MockRemoteScanAPI: RemoteScanAPI {
    private var outcomes: [MockRemoteOutcome]
    private var receivedUploads: [UploadScanRequestDTO] = []

    public init(outcomes: [MockRemoteOutcome] = []) {
        self.outcomes = outcomes
    }

    public func upload(_ request: UploadScanRequestDTO) async throws -> UploadScanResponseDTO {
        receivedUploads.append(request)
        let outcome = outcomes.isEmpty ? defaultSuccess(for: request) : outcomes.removeFirst()

        switch outcome {
        case let .success(remoteID, revision, wasCreated):
            let scan = RemoteScanDTO(
                id: remoteID,
                localScanID: request.localScanID,
                displayName: request.displayName,
                checksumSHA256: request.checksumSHA256,
                revision: revision,
                updatedAt: request.updatedAt
            )
            return UploadScanResponseDTO(scan: scan, wasCreated: wasCreated)
        case .offline:
            throw RemoteAPIError.offline
        case let .retryable(message):
            throw RemoteAPIError.retryable(message: message)
        case let .rejected(message):
            throw RemoteAPIError.rejected(message: message)
        case let .conflict(current):
            throw RemoteAPIError.conflict(current: current)
        case .cancelled:
            throw RemoteAPIError.cancelled
        }
    }

    public func append(outcome: MockRemoteOutcome) {
        outcomes.append(outcome)
    }

    public func uploadRequests() -> [UploadScanRequestDTO] {
        receivedUploads
    }

    private func defaultSuccess(for request: UploadScanRequestDTO) -> MockRemoteOutcome {
        .success(
            remoteID: "scan-\(request.localScanID.uuidString.lowercased())",
            revision: "1",
            wasCreated: true
        )
    }
}
