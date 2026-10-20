import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SideKickCore

final class RemoteAnisetteConfigurationTests: XCTestCase {
    private func list(url: String = "https://ani.example.com", headers: [String: String]? = nil, recommended: String = "main", schema: Int = 1) -> Data {
        let headers = headers ?? ["X-Mme-Client-Info": "<PC> <Windows>", "User-Agent": "akd/1.0"]
        let object: [String: Any] = [
            "schemaVersion": schema,
            "updatedAt": "2026-10-19T08:30:00Z",
            "recommended": recommended,
            "servers": [["id": "main", "name": "Main", "url": url, "headers": headers]]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testShippedRepositoryFileIsValid() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(RemoteAnisetteConfiguration.repositoryPath)
        let decoded = try RemoteAnisetteConfiguration.decode(Data(contentsOf: file))
        let selection = try RemoteAnisetteConfiguration.validatedSelection(from: decoded, lastUpdated: nil)
        XCTAssertEqual(selection.serverURL.scheme, "https")
        XCTAssertNotNil(selection.lastUpdated)
    }

    func testDecodesRecommendedServerAndHeaders() throws {
        let selection = try RemoteAnisetteConfiguration.validatedSelection(
            from: RemoteAnisetteConfiguration.decode(list()), lastUpdated: nil)
        XCTAssertEqual(selection.server.clientInfo, "<PC> <Windows>")
        XCTAssertEqual(selection.server.userAgent, "akd/1.0")
        XCTAssertEqual(selection.serverURL.absoluteString, "https://ani.example.com")
        XCTAssertEqual(selection.lastUpdated, RemoteAnisetteConfiguration.parseDate("2026-10-19T08:30:00Z"))
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let data = list(headers: ["x-mme-client-info": "client", "user-agent": "agent"])
        let selection = try RemoteAnisetteConfiguration.validatedSelection(from: RemoteAnisetteConfiguration.decode(data), lastUpdated: nil)
        XCTAssertEqual(selection.server.clientInfo, "client")
        XCTAssertEqual(selection.server.userAgent, "agent")
    }

    func testRejectsUnsafeOrIncompleteServers() throws {
        func error(_ data: Data) -> RemoteAnisetteConfigurationError? {
            do {
                _ = try RemoteAnisetteConfiguration.validatedSelection(from: RemoteAnisetteConfiguration.decode(data), lastUpdated: nil)
                return nil
            } catch { return error as? RemoteAnisetteConfigurationError }
        }
        XCTAssertEqual(error(list(url: "http://ani.example.com")), .unsafeServer("Main"))
        XCTAssertEqual(error(list(url: "http://localhost:6969")), .unsafeServer("Main"))
        XCTAssertEqual(error(list(headers: ["User-Agent": "akd"])), .missingHeaders("Main"))
        XCTAssertEqual(error(list(headers: ["X-Mme-Client-Info": "a\r\nInjected: 1", "User-Agent": "akd"])), .missingHeaders("Main"))
        XCTAssertEqual(error(list(headers: ["X-Mme-Client-Info": "a", "User-Agent": "b", "X-Device": "c"])), .unsupportedHeader("X-Device"))
        XCTAssertEqual(error(list(recommended: "missing")), .noRecommendedServer)
        XCTAssertEqual(error(list(schema: 2)), .unsupportedSchema)
        XCTAssertEqual(error(Data("not json".utf8)), .invalidFile)
        XCTAssertEqual(error(Data(repeating: 0x20, count: RemoteAnisetteConfiguration.maximumSize + 1)), .invalidFile)
    }

    func testClientPrefersCommitDateAndToleratesHistoryFailure() async throws {
        let body = list()
        let commit = Data(#"[{"commit":{"committer":{"date":"2026-10-20T10:00:00Z"}}}]"#.utf8)
        let withHistory = RemoteAnisetteConfigurationClient { request in
            let data = request.url == RemoteAnisetteConfiguration.fileURL ? body : commit
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let selection = try await withHistory.fetchRecommended()
        XCTAssertEqual(selection.lastUpdated, RemoteAnisetteConfiguration.parseDate("2026-10-20T10:00:00Z"))

        let rateLimited = RemoteAnisetteConfigurationClient { request in
            let ok = request.url == RemoteAnisetteConfiguration.fileURL
            return (ok ? body : Data(), HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 403, httpVersion: nil, headerFields: nil)!)
        }
        let fallback = try await rateLimited.fetchRecommended()
        XCTAssertEqual(fallback.lastUpdated, RemoteAnisetteConfiguration.parseDate("2026-10-19T08:30:00Z"))
    }

    func testBootstrapSkipsOptionalHistoryRequest() async throws {
        let data = list()
        let client = RemoteAnisetteConfigurationClient { request in
            XCTAssertEqual(request.url, RemoteAnisetteConfiguration.fileURL)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let selection = try await client.fetchRecommended(includeHistory: false)
        XCTAssertEqual(selection.lastUpdated, RemoteAnisetteConfiguration.parseDate("2026-10-19T08:30:00Z"))
    }

    func testClientReportsMissingFile() async {
        let client = RemoteAnisetteConfigurationClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.fetchRecommended(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? RemoteAnisetteConfigurationError, .unavailable(404)) }
    }

    func testAnisetteHintOnlyForAnisetteErrors() {
        let anisette = NSError(domain: "SideSign.AnisetteError", code: 3)
        let wrapped = NSError(domain: "AltServer", code: 1, userInfo: [NSUnderlyingErrorKey: anisette])
        let unrelated = NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"])
        XCTAssertTrue(AnisetteErrorHint.isAnisetteRelated(anisette))
        XCTAssertTrue(AnisetteErrorHint.isAnisetteRelated(wrapped))
        XCTAssertFalse(AnisetteErrorHint.isAnisetteRelated(unrelated))
        XCTAssertTrue(AnisetteErrorHint.message(for: wrapped).hasSuffix(AnisetteErrorHint.suggestion))
        XCTAssertEqual(AnisetteErrorHint.message(for: unrelated), "Offline")
    }
}
