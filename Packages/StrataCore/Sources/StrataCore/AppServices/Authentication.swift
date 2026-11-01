import Foundation

public struct AuthenticatedAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum AuthenticationFailure: String, Codable, Equatable, Sendable {
    case invalidCredentials
    case cancelled
    case unavailable
    case credentialStorage
}

public enum AuthenticationState: Equatable, Sendable {
    case unknown
    case unauthenticated
    case authenticating
    case authenticated(AuthenticatedAccount)
    case failed(AuthenticationFailure)
}

public protocol AuthenticationServicing: Sendable {
    func state() async -> AuthenticationState
    func restore() async -> AuthenticationState
    func authenticate() async -> AuthenticationState
    func signOut() async -> AuthenticationState
}

public enum MockAuthenticationOutcome: Equatable, Sendable {
    case authenticated(account: AuthenticatedAccount, credential: AuthenticationCredential)
    case failed(AuthenticationFailure)
}

/// Scripted authentication for Mock configuration and deterministic tests. A
/// future identity-provider adapter can conform to the same protocol.
public actor MockAuthenticationService: AuthenticationServicing {
    private let credentialStore: any SecureCredentialStoring
    private var outcomes: [MockAuthenticationOutcome]
    private var currentState: AuthenticationState

    public init(
        credentialStore: any SecureCredentialStoring,
        outcomes: [MockAuthenticationOutcome] = [],
        initialState: AuthenticationState = .unknown
    ) {
        self.credentialStore = credentialStore
        self.outcomes = outcomes
        currentState = initialState
    }

    public func state() async -> AuthenticationState {
        currentState
    }

    public func restore() async -> AuthenticationState {
        do {
            guard let credential = try await credentialStore.load() else {
                currentState = .unauthenticated
                return currentState
            }
            currentState = .authenticated(credential.account)
        } catch {
            currentState = .failed(.credentialStorage)
        }
        return currentState
    }

    public func authenticate() async -> AuthenticationState {
        currentState = .authenticating
        guard !outcomes.isEmpty else {
            currentState = .failed(.unavailable)
            return currentState
        }

        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .authenticated(account, credential):
            guard account.id == credential.accountID else {
                currentState = .failed(.credentialStorage)
                return currentState
            }
            do {
                try await credentialStore.save(credential)
                currentState = .authenticated(account)
            } catch {
                currentState = .failed(.credentialStorage)
            }
        case let .failed(failure):
            currentState = .failed(failure)
        }
        return currentState
    }

    public func signOut() async -> AuthenticationState {
        do {
            try await credentialStore.remove()
            currentState = .unauthenticated
        } catch {
            currentState = .failed(.credentialStorage)
        }
        return currentState
    }
}
