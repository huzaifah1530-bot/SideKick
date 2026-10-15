import Foundation
import SideSign

/// Bridges typed library events into the same operation as the calling UI/service.
/// Ordinary vendor console output is deliberately never copied into this store.
@MainActor enum SideKickDiagnostics {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AuthenticationDiagnostics.notification, object: nil, queue: nil) { notification in
            guard let fields = notification.userInfo,
                  let rawID = fields["operationID"] as? String, let id = UUID(uuidString: rawID),
                  let rawOperation = fields["operation"] as? String, let operation = DiagnosticsStore.Operation(rawValue: rawOperation),
                  let rawStage = fields["stage"] as? String, let stage = DiagnosticsStore.Stage(rawValue: rawStage),
                  let rawEvent = fields["event"] as? String, let event = DiagnosticsStore.Event(rawValue: rawEvent) else { return }
            DiagnosticsStore.shared.record(event, operation: operation, stage: stage, operationID: id,
                errorKind: .apple, code: fields["code"] as? Int, httpStatus: fields["httpStatus"] as? Int,
                challengeStatus: fields["challengeStatus"] as? Int)
        }
    }

    static func perform<T>(_ operation: DiagnosticsStore.Operation, stage: DiagnosticsStore.Stage,
        body: () async throws -> T) async rethrows -> T {
        start()
        return try await DiagnosticsStore.perform(operation, stage: stage) {
            try await AuthenticationDiagnostics.$operationID.withValue(DiagnosticsStore.operationID) {
                try await AuthenticationDiagnostics.$entryPoint.withValue(operation.rawValue) {
                    do { return try await body() }
                    catch {
                        if let server = error as? SideSign.ServerError,
                           case .underlyingError(let code, _) = server,
                           let id = DiagnosticsStore.operationID {
                            DiagnosticsStore.shared.record(.failed, operation: operation, stage: stage, operationID: id, errorKind: .apple, code: code)
                        }
                        throw error
                    }
                }
            }
        }
    }
}
