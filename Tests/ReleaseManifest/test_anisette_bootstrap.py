"""Exercise the shipping first-launch method with isolated persistence and transport."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AnisetteBootstrapTests(unittest.TestCase):
    def test_setup_finishes_before_home_becomes_ready(self):
        source = (ROOT / 'SideKick/App/AppEnvironment.swift').read_text()
        start = source[source.index('func startDatabase()'):source.index('func reloadLocalCatalogues(')]
        self.assertLess(start.index('await SigningAccountStore().applyNewestAnisetteOnFirstLaunch()'),
                        start.index('databaseState = .ready'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for bootstrap behavior tests')
    def test_first_launch_success_offline_existing_choice_and_download_race(self):
        source = (ROOT / 'SideKick/Services/SigningAccountStore.swift').read_text()
        method = source[source.index('    func applyNewestAnisetteOnFirstLaunch()'):source.index('    private func hasNoAnisetteChoice()')]
        fixture = r'''
import Foundation
struct Server { let name = "Recommended"; let id = "recommended"; let clientInfo = "client"; let userAgent = "agent" }
struct Selection { let server = Server(); let serverURL = URL(string: "https://example.com")! }
@MainActor enum State {
    static var choice = false
    static var offline = false
    static var chooseWhileDownloading = false
    static var applied = 0
    static var downloads = 0
}
struct RemoteAnisetteConfigurationClient {
    @MainActor func fetchRecommended(includeHistory: Bool = true) async throws -> Selection {
        precondition(!includeHistory, "Startup must not wait on optional GitHub history")
        State.downloads += 1
        if State.offline { throw NSError(domain: "offline", code: 1) }
        if State.chooseWhileDownloading { State.choice = true }
        return Selection()
    }
}
@MainActor enum SigningAccountOperationCoordinator {
    static var busy = false
    static func acquire() -> Bool { if busy { return false }; busy = true; return true }
    static func release() { busy = false }
}
@MainActor final class AppManager {
    static let shared = AppManager()
    var isActivelyManagingAnyApp = false
}
@MainActor enum AppOffloadService { static var isRunning = false }
@MainActor enum SideKickStorageCleanup { static var hasActiveOperations = false }
struct AnisetteRemoteRecord { let serverID: String; let appliedAt: Date; func save() {} }
func debugLog(_ value: String) {}
@MainActor final class Store {
    func hasNoAnisetteChoice() async -> Bool { !State.choice }
    func applyAnisetteDefault(name: String, server: String, clientInfo: String, userAgent: String) async {
        State.applied += 1; State.choice = true
    }
METHOD
}
@main struct Main {
    @MainActor static func main() async {
        let key = "sidekick.anisette.first-launch-newest.v1"
        func reset() {
            UserDefaults.standard.removeObject(forKey: key)
            State.choice = false; State.offline = false; State.chooseWhileDownloading = false
            State.applied = 0; State.downloads = 0
            SigningAccountOperationCoordinator.busy = false
            AppManager.shared.isActivelyManagingAnyApp = false
            AppOffloadService.isRunning = false
            SideKickStorageCleanup.hasActiveOperations = false
        }
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = Store()
        reset()
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 1 && UserDefaults.standard.bool(forKey: key))
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.downloads == 1 && State.applied == 1)
        reset(); State.offline = true
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 0 && !UserDefaults.standard.bool(forKey: key))
        State.offline = false
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 1)
        reset(); State.choice = true
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.downloads == 0 && State.applied == 0)
        reset(); State.chooseWhileDownloading = true
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 0, "A user choice made during the download must survive")
        reset(); SigningAccountOperationCoordinator.busy = true
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 0 && !UserDefaults.standard.bool(forKey: key))
        SigningAccountOperationCoordinator.busy = false
        await store.applyNewestAnisetteOnFirstLaunch()
        precondition(State.applied == 1)
        for blocker in 0..<3 {
            reset()
            AppManager.shared.isActivelyManagingAnyApp = blocker == 0
            AppOffloadService.isRunning = blocker == 1
            SideKickStorageCleanup.hasActiveOperations = blocker == 2
            await store.applyNewestAnisetteOnFirstLaunch()
            precondition(State.applied == 0 && !UserDefaults.standard.bool(forKey: key))
            AppManager.shared.isActivelyManagingAnyApp = false
            AppOffloadService.isRunning = false
            SideKickStorageCleanup.hasActiveOperations = false
            await store.applyNewestAnisetteOnFirstLaunch()
            precondition(State.applied == 1)
        }
        print("Anisette bootstrap behavior passed")
    }
}
'''.replace('METHOD', method)
        with tempfile.TemporaryDirectory(prefix='sidekick-anisette-') as directory:
            path = Path(directory)
            source_path = path / 'Bootstrap.swift'
            source_path.write_text(fixture)
            binary = path / 'bootstrap'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source_path), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
