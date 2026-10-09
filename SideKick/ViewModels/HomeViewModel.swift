import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    var apps: [SideloadedApp] = []
    var accounts: [AppleAccount] = []
    var isRefreshing = false
    var errorMessage: String?

    private let service: any SideloadingService

    init(service: any SideloadingService) { self.service = service }

    func load() async {
        do {
            async let loadedApps = service.installedApps()
            async let loadedAccounts = service.accounts()
            apps = try await loadedApps
            accounts = try await loadedAccounts
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do { apps = try await service.refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func refresh(_ app: SideloadedApp) async {
        guard let index = apps.firstIndex(of: app) else { return }
        apps[index].status = .refreshing
        do { apps[index] = try await service.refresh(app: app) }
        catch { apps[index].status = .needsAttention; errorMessage = error.localizedDescription }
    }
}
