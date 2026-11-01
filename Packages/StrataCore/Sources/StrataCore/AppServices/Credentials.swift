import Foundation
import Security

public struct AuthenticationCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accountID: String
    public var accountDisplayName: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(
        accountID: String,
        accountDisplayName: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.accountID = accountID
        self.accountDisplayName = accountDisplayName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var account: AuthenticatedAccount {
        AuthenticatedAccount(id: accountID, displayName: accountDisplayName)
    }

    public var description: String {
        "AuthenticationCredential(accountID: \(accountID), token: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

public protocol SecureCredentialStoring: Sendable {
    func save(_ credential: AuthenticationCredential) async throws
    func load() async throws -> AuthenticationCredential?
    func remove() async throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
    case keychain(status: Int32)
}

/// Injected storage for tests and Mock configuration. Product credentials use
/// the Keychain implementation below.
public actor InMemoryCredentialStore: SecureCredentialStoring {
    private var credential: AuthenticationCredential?

    public init(credential: AuthenticationCredential? = nil) {
        self.credential = credential
    }

    public func save(_ credential: AuthenticationCredential) async throws {
        self.credential = credential
    }

    public func load() async throws -> AuthenticationCredential? {
        credential
    }

    public func remove() async throws {
        credential = nil
    }
}

/// Keychain-backed credential storage. The caller owns the stable service name
/// so app, test, and future extensions do not accidentally share credentials.
public actor KeychainCredentialStore: SecureCredentialStoring {
    private let service: String
    private let account: String

    public init(service: String, account: String = "stratascan.authentication") {
        self.service = service
        self.account = account
    }

    public func save(_ credential: AuthenticationCredential) async throws {
        let data: Data
        do {
            data = try RemoteAPICodec.encode(credential)
        } catch {
            throw CredentialStoreError.encodingFailed
        }

        let query = baseQuery()
        let update = [kSecValueData: data] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, update)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(status: addStatus)
        }
    }

    public func load() async throws -> AuthenticationCredential? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status: status)
        }
        guard let result, let data = result as? Data else {
            throw CredentialStoreError.decodingFailed
        }

        do {
            return try RemoteAPICodec.decode(AuthenticationCredential.self, from: data)
        } catch {
            throw CredentialStoreError.decodingFailed
        }
    }

    public func remove() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}

/// Bridges secure credentials into the HTTP transport without exposing tokens to
/// alert, logging, or UI state layers.
public actor CredentialAuthorizationProvider: RemoteAuthorizationProviding {
    private let credentialStore: any SecureCredentialStoring
    private let clock: @Sendable () -> Date

    public init(
        credentialStore: any SecureCredentialStoring,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.clock = clock
    }

    public func authorizationHeader() async throws -> String? {
        guard let credential = try await credentialStore.load(), !credential.accessToken.isEmpty else {
            return nil
        }
        if let expiresAt = credential.expiresAt, expiresAt <= clock() {
            return nil
        }
        return "Bearer \(credential.accessToken)"
    }
}
