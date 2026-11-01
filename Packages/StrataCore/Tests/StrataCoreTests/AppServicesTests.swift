import Foundation
import Testing
@testable import StrataCore

@Suite("Authentication credentials and alerts")
struct AppServicesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Mock authentication persists credentials through the secure abstraction")
    func mockAuthenticationTransitionsAndSignsOut() async throws {
        let account = AuthenticatedAccount(id: "user-1", displayName: "Taylor")
        let credential = AuthenticationCredential(
            accountID: account.id,
            accountDisplayName: account.displayName,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let store = InMemoryCredentialStore()
        let service = MockAuthenticationService(
            credentialStore: store,
            outcomes: [.authenticated(account: account, credential: credential)]
        )

        #expect(await service.state() == .unknown)
        #expect(await service.restore() == .unauthenticated)
        #expect(await service.authenticate() == .authenticated(account))
        #expect(try await store.load() == credential)
        #expect(await service.signOut() == .unauthenticated)
        #expect(try await store.load() == nil)
    }

    @Test("Mock authentication exposes a deterministic failed state")
    func mockAuthenticationFailure() async {
        let service = MockAuthenticationService(
            credentialStore: InMemoryCredentialStore(),
            outcomes: [.failed(.invalidCredentials)]
        )

        let state = await service.authenticate()

        #expect(state == .failed(.invalidCredentials))
    }

    @Test("Credential authorization omits expired tokens")
    func authorizationProviderHandlesExpiration() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(
            AuthenticationCredential(
                accountID: "user-2",
                accountDisplayName: "Morgan",
                accessToken: "short-lived-token",
                expiresAt: now.addingTimeInterval(-1)
            )
        )
        let authorization = CredentialAuthorizationProvider(credentialStore: store, clock: { now })

        let header = try await authorization.authorizationHeader()

        #expect(header == nil)
    }

    @Test("Sync states map to actionable structured alerts")
    func mapsSyncStatesToAlerts() {
        let request = UploadScanRequestDTO(
            idempotencyKey: UUID(),
            localScanID: UUID(),
            remoteScanID: "scan-remote-3",
            displayName: "Atrium",
            checksumSHA256: "feed",
            expectedRevision: "1",
            updatedAt: now
        )
        let conflict = SyncQueueItem(
            request: request,
            state: .conflict,
            lastFailure: .conflict,
            createdAt: now,
            updatedAt: now
        )
        let retry = SyncQueueItem(
            request: request,
            state: .retryScheduled,
            retryCount: 1,
            nextAttemptAt: now.addingTimeInterval(30),
            lastFailure: .offline,
            createdAt: now,
            updatedAt: now
        )

        let conflictAlert = AlertCatalog.sync(for: conflict)
        let retryAlert = AlertCatalog.sync(for: retry)

        #expect(conflictAlert?.source == .sync)
        #expect(conflictAlert?.presentation == .modalConfirmation)
        #expect(conflictAlert?.actions.map(\.intent) == [.resolveSyncConflict, .dismiss])
        #expect(retryAlert?.presentation == .transientBanner)
        #expect(retryAlert?.actions.map(\.intent) == [.dismiss])
    }
}
