import Foundation

public enum RemoteAPIVersion {
    public static let current = "v1"
}

/// Wire representation of a scan. It deliberately contains no local file paths
/// or binary asset data; those remain managed by the local scan package.
public struct RemoteScanDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var localScanID: UUID
    public var displayName: String
    public var checksumSHA256: String
    public var revision: String
    public var updatedAt: Date

    public init(
        id: String,
        localScanID: UUID,
        displayName: String,
        checksumSHA256: String,
        revision: String,
        updatedAt: Date
    ) {
        self.id = id
        self.localScanID = localScanID
        self.displayName = displayName
        self.checksumSHA256 = checksumSHA256
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct UploadScanRequestDTO: Codable, Equatable, Sendable {
    /// Reused after interruption so the remote can safely deduplicate a replay.
    public var idempotencyKey: UUID
    public var localScanID: UUID
    public var remoteScanID: String?
    public var displayName: String
    public var checksumSHA256: String
    public var expectedRevision: String?
    public var updatedAt: Date

    public init(
        idempotencyKey: UUID,
        localScanID: UUID,
        remoteScanID: String? = nil,
        displayName: String,
        checksumSHA256: String,
        expectedRevision: String? = nil,
        updatedAt: Date
    ) {
        self.idempotencyKey = idempotencyKey
        self.localScanID = localScanID
        self.remoteScanID = remoteScanID
        self.displayName = displayName
        self.checksumSHA256 = checksumSHA256
        self.expectedRevision = expectedRevision
        self.updatedAt = updatedAt
    }
}

public struct UploadScanResponseDTO: Codable, Equatable, Sendable {
    public var scan: RemoteScanDTO
    public var wasCreated: Bool

    public init(scan: RemoteScanDTO, wasCreated: Bool) {
        self.scan = scan
        self.wasCreated = wasCreated
    }
}

public struct RemoteErrorDTO: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var currentScan: RemoteScanDTO?

    public init(code: String, message: String, currentScan: RemoteScanDTO? = nil) {
        self.code = code
        self.message = message
        self.currentScan = currentScan
    }
}

public enum RemoteAPIError: Error, Equatable, Sendable {
    case offline
    case unauthorized
    case retryable(message: String)
    case rejected(message: String)
    case conflict(current: RemoteScanDTO?)
    case invalidResponse(message: String)
    case cancelled
}

/// The injected API boundary keeps remote DTOs separate from local scan models.
public protocol RemoteScanAPI: Sendable {
    func upload(_ request: UploadScanRequestDTO) async throws -> UploadScanResponseDTO
}

/// Supplies an authorization value without making the transport depend on a
/// particular credential store or authentication provider.
public protocol RemoteAuthorizationProviding: Sendable {
    func authorizationHeader() async throws -> String?
}

public enum RemoteAPICodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// Concrete HTTP adapter for a configured remote. It has no mock-specific
/// behavior; mock routing stays in the Mock configuration and injected mock API.
public struct URLSessionRemoteScanAPI: RemoteScanAPI {
    private let baseURL: URL
    private let session: URLSession
    private let authorization: (any RemoteAuthorizationProviding)?

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        authorization: (any RemoteAuthorizationProviding)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authorization = authorization
    }

    public func upload(_ request: UploadScanRequestDTO) async throws -> UploadScanResponseDTO {
        let body: Data
        do {
            body = try RemoteAPICodec.encode(request)
        } catch {
            throw RemoteAPIError.invalidResponse(message: "Unable to encode the upload request.")
        }

        var urlRequest = URLRequest(url: baseURL.appending(path: "scans"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await execute(urlRequest)
        switch response.statusCode {
        case 200 ... 299:
            do {
                return try RemoteAPICodec.decode(UploadScanResponseDTO.self, from: data)
            } catch {
                throw RemoteAPIError.invalidResponse(message: "The remote returned an invalid upload response.")
            }
        case 401, 403:
            throw RemoteAPIError.unauthorized
        case 409:
            let remoteError = try? RemoteAPICodec.decode(RemoteErrorDTO.self, from: data)
            throw RemoteAPIError.conflict(current: remoteError?.currentScan)
        case 408, 425, 429, 500 ... 599:
            throw RemoteAPIError.retryable(message: "The remote is temporarily unavailable.")
        default:
            throw RemoteAPIError.rejected(message: "The remote rejected the upload request.")
        }
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var signedRequest = request
        if let authorization,
           let header = try await authorization.authorizationHeader(),
           !header.isEmpty {
            signedRequest.setValue(header, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: signedRequest)
            guard let response = response as? HTTPURLResponse else {
                throw RemoteAPIError.invalidResponse(message: "The remote did not return an HTTP response.")
            }
            return (data, response)
        } catch let error as RemoteAPIError {
            throw error
        } catch is CancellationError {
            throw RemoteAPIError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                throw RemoteAPIError.offline
            default:
                throw RemoteAPIError.retryable(message: "The remote request could not be completed.")
            }
        } catch {
            throw RemoteAPIError.retryable(message: "The remote request could not be completed.")
        }
    }
}
