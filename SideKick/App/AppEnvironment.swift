import Foundation
import Observation

enum DatabaseStartupState: Equatable {
    case starting
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppEnvironment {
    let ipaImportStore: IPAImportStore
    private(set) var databaseState: DatabaseStartupState = .starting

    init(ipaImportStore: IPAImportStore = IPAImportStore()) {
        self.ipaImportStore = ipaImportStore
    }

    func startDatabase() async {
        if case .ready = databaseState { return }
        databaseState = .starting
        do {
            try await DatabaseManager.shared.start()
            databaseState = .ready
        } catch {
            databaseState = .failed(Self.readableDescription(for: error))
        }
    }

    private static func readableDescription(for error: Error) -> String {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            details.append(reason)
        }
        if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
            details.append(debug)
        }
        return Array(NSOrderedSet(array: details)).compactMap { $0 as? String }.joined(separator: "\n\n")
    }
}
