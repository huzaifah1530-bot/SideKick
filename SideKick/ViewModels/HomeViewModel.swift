import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    var importedApps: [ImportedIPA] = []
    var isImporting = false
    var errorMessage: String?
    var noticeMessage: String?

    private let store: IPAImportStore

    init(store: IPAImportStore) { self.store = store }

    func load() async {
        do { importedApps = try await store.importedApps() }
        catch { errorMessage = error.localizedDescription }
    }

    func importIPA(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let app = try await store.importIPA(from: url)
            importedApps = try await store.importedApps()
            noticeMessage = "\(app.name) is ready to install."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ app: ImportedIPA) async {
        do {
            try await store.delete(app)
            importedApps = try await store.importedApps()
        } catch { errorMessage = error.localizedDescription }
    }
}
