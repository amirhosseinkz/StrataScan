import Foundation
import Testing
@testable import StrataCore

@Suite("Remote API protocol")
struct RemoteAPITests {
    @Test("DTOs use the versioned API's ISO-8601 wire format")
    func encodesAndDecodesUploadRequest() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = UploadScanRequestDTO(
            idempotencyKey: UUID(),
            localScanID: UUID(),
            remoteScanID: "scan-remote-1",
            displayName: "West stairwell",
            checksumSHA256: "a3f5",
            expectedRevision: "7",
            updatedAt: updatedAt
        )

        let encoded = try RemoteAPICodec.encode(request)
        let decoded = try RemoteAPICodec.decode(UploadScanRequestDTO.self, from: encoded)

        #expect(decoded == request)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"updatedAt\":\"2023-11-14T22:13:20Z\""))
    }

    @Test("The injected mock remote returns scripted typed outcomes")
    func mockRemoteReturnsScriptedResponse() async throws {
        let request = UploadScanRequestDTO(
            idempotencyKey: UUID(),
            localScanID: UUID(),
            displayName: "Boiler room",
            checksumSHA256: "0f0f",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let remote = MockRemoteScanAPI(outcomes: [
            .success(remoteID: "scan-42", revision: "3", wasCreated: false)
        ])

        let response = try await remote.upload(request)
        let receivedRequests = await remote.uploadRequests()

        #expect(response.scan.id == "scan-42")
        #expect(response.scan.revision == "3")
        #expect(!response.wasCreated)
        #expect(receivedRequests == [request])
    }
}
