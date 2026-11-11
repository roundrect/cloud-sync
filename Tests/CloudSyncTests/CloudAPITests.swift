import Foundation
import Testing
@testable import CloudSync

@Suite("CloudAPI")
struct CloudAPITests {
    @Test func plainHttpIsOnlyForLoopback() {
        #expect(CloudAPI.isAllowed(URL(string: "https://sync.example.com")!))
        #expect(CloudAPI.isAllowed(URL(string: "http://127.0.0.1:8787")!))
        #expect(CloudAPI.isAllowed(URL(string: "http://localhost")!))
        #expect(CloudAPI.isAllowed(URL(string: "http://[::1]:8787")!))
        #expect(!CloudAPI.isAllowed(URL(string: "http://example.com")!))
        #expect(!CloudAPI.isAllowed(URL(string: "ftp://localhost")!))
        #expect(CloudAPI.isLoopback(URL(string: "http://LOCALHOST:1")!))
        #expect(!CloudAPI.isLoopback(URL(string: "https://sync.example.com")!))
        #expect(throws: CloudError.self) { try CloudAPI.requireAllowed(URL(string: "http://example.com")!) }
    }

    @Test func serversCompareIgnoringCaseAndATrailingSlash() {
        #expect(CloudAPI.sameServer(URL(string: "https://Sync.Example.com/")!, URL(string: "https://sync.example.com")!))
        #expect(!CloudAPI.sameServer(URL(string: "https://a.example.com")!, URL(string: "https://b.example.com")!))
    }

    @Test func aServerAddressIsTrimmedAndChecked() throws {
        #expect(try CloudAPI.normalizedServer("  https://sync.example.com//  ").absoluteString == "https://sync.example.com")
        #expect(throws: CloudError.self) { _ = try CloudAPI.normalizedServer("not a url") }
        #expect(throws: CloudError.self) { _ = try CloudAPI.normalizedServer("") }
    }

    @Test func statusCodesMapOntoErrors() {
        func body(_ error: String?, _ message: String = "m") -> Data {
            Data((error.map { #"{"error":"\#($0)","message":"\#(message)"}"# } ?? #"{"message":"\#(message)"}"#).utf8)
        }
        #expect(CloudAPI.error(status: 401, body: body("invalid_invite")) == .invalidInvite)
        #expect(CloudAPI.error(status: 401, body: body("unauthorized", "gone")) == .unauthorized("gone"))
        #expect(CloudAPI.error(status: 402, body: Data()) == .paymentRequired)
        #expect(CloudAPI.error(status: 404, body: body("invalid_code")) == .invalidCode)
        #expect(CloudAPI.error(status: 404, body: body("not_found", "nope")) == .notFound("nope"))
        #expect(CloudAPI.error(status: 403, body: body("namespace_mismatch", "other app")) == .namespaceMismatch("other app"))
        #expect(CloudAPI.error(status: 403, body: body("forbidden", "no")) == .server(status: 403, message: "no"))
        #expect(CloudAPI.error(status: 426, body: body("upgrade_required", "old")) == .upgradeRequired("old"))
        #expect(CloudAPI.error(status: 429, body: body("rate_limited", "slow")) == .rateLimited("slow"))
        #expect(CloudAPI.error(status: 500, body: Data("<html>".utf8)) == .server(status: 500, message: "HTTP 500"))
        #expect(CloudAPI.error(status: 409, body: Data("nonsense".utf8)) == .server(status: 409, message: "HTTP 409"))
        let conflict = Data(#"{"error":"conflict","rev":5,"format":"app-text","schema":1,"body":"b","sha256":"s"}"#.utf8)
        guard case .conflict(let remote) = CloudAPI.error(status: 409, body: conflict) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(remote.rev == 5)
        #expect(remote.body == "b")
    }

    @Test func requestsCarryTheClientVersionAndTheTokenUnderNeutralNames() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes(["a": "1"]))
        _ = try await mac.linkCreate()
        _ = try await mac.cloud.status()
        let request = try #require(server.requests.last { $0.url.path == "/v1/ns/app/doc" })
        #expect(request.header("Sync-Client") == "1.2.3")
        #expect(request.header("Authorization")?.hasPrefix("Bearer ") == true)
        #expect(server.requests.allSatisfy { $0.header("Old-Client-Header") == nil })
        #expect(server.requests.allSatisfy { $0.header("Sync-Client") == "1.2.3" })
    }

    @Test func theMetaEndpointAnswers() async throws {
        let meta = try await CloudAPI(server: FakeMacURL.url, transport: FakeCloudServer(), clientVersion: "1", namespace: "app").meta()
        #expect(meta.api == 1)
        #expect(meta.minClient == "0.0.0")
    }
}

private enum FakeMacURL { static let url = URL(string: "http://127.0.0.1:8787")! }
