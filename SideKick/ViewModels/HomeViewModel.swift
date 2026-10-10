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
    private var loadGeneration = UUID()

    init(store: IPAImportStore) { self.store = store }

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        do {
            let apps = try await store.importedApps()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            importedApps = apps
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func importIPA(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let app = try await store.importIPA(from: url)
            await load()
            noticeMessage = "\(app.name) is ready to install."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ app: ImportedIPA) async {
        do {
            try await store.delete(app)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
