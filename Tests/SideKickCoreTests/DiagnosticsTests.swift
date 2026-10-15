import Foundation
import XCTest
@testable import SideKickCore

final class DiagnosticsTests: XCTestCase {
    func testNumericUnderlyingErrorsSurviveWithoutSecretText() throws {
        let store = DiagnosticsStore()
        let underlying = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSLocalizedDescriptionKey: "password=secret", NSURLErrorFailingURLStringErrorKey: "https://secret@example.com/?token=secret"])
        let error = NSError(domain: "secret-domain", code: -80045, userInfo: [
            NSLocalizedDescriptionKey: "secret-body", NSUnderlyingErrorKey: underlying])
        let id = UUID()
        store.failure(error, operation: .addAccount, stage: .authComplete, operationID: id)
        let entries = store.snapshot().entries
        XCTAssertEqual(entries.map(\.code), [-1001, -80045])
        XCTAssertTrue(entries.allSatisfy { $0.operationID == id })
        let output = DiagnosticsStore.export(entries)
        XCTAssertTrue(output.contains("authComplete"))
        XCTAssertTrue(output.contains("-80045"))
        XCTAssertFalse(output.contains("secret"))
    }

    func testPersistenceBoundExportAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.json")
        let store = DiagnosticsStore(fileURL: file, limit: 2)
        let id = UUID()
        for status in [200, 409, 503] {
            store.record(.response, operation: .addAccount, stage: .authComplete, operationID: id, errorKind: .apple, code: -22411, httpStatus: status, challengeStatus: 409)
        }
        let restored = DiagnosticsStore(fileURL: file, limit: 2)
        XCTAssertEqual(restored.snapshot().entries.map(\.httpStatus), [503, 409])
        XCTAssertTrue(DiagnosticsStore.export(restored.snapshot().entries).contains("HTTP 503"))
        XCTAssertTrue(DiagnosticsStore.export(restored.snapshot().entries).contains("Apple status 409"))
        XCTAssertFalse(restored.snapshot().persistenceFailed)
        restored.clear()
        XCTAssertTrue(DiagnosticsStore(fileURL: file).snapshot().entries.isEmpty)
    }

    @MainActor func testStagesShareOperationIDAndFailurePropagates() async {
        enum Probe: Error { case failed }
        do {
            try await DiagnosticsStore.perform(.install, stage: .installation) {
                let id = DiagnosticsStore.operationID
                XCTAssertNotNil(id)
                try await DiagnosticsStore.perform(.install, stage: .localConnection) {
                    XCTAssertEqual(DiagnosticsStore.operationID, id)
                    throw Probe.failed
                }
            }
            XCTFail("Must propagate failure")
        } catch { XCTAssertTrue(error is Probe) }
        XCTAssertNil(DiagnosticsStore.operationID)
    }
}
