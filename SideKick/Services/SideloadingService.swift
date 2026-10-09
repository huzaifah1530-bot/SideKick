import Foundation

protocol SideloadingService: Sendable {
    func installedApps() async throws -> [SideloadedApp]
    func accounts() async throws -> [AppleAccount]
    func refresh(app: SideloadedApp) async throws -> SideloadedApp
    func refreshAll() async throws -> [SideloadedApp]
}

struct DemoSideloadingService: SideloadingService {
    func installedApps() async throws -> [SideloadedApp] {
        [
            SideloadedApp(id: UUID(), name: "Delta", bundleIdentifier: "com.rileytestut.Delta", version: "1.7.1", iconSystemName: "gamecontroller.fill", accent: .purple, expiresAt: .now.addingTimeInterval(86400 * 6), status: .active, signingAccountID: nil),
            SideloadedApp(id: UUID(), name: "Clip", bundleIdentifier: "com.sidekick.Clip", version: "2.4.0", iconSystemName: "scissors", accent: .orange, expiresAt: .now.addingTimeInterval(86400 * 2), status: .needsAttention, signingAccountID: nil),
            SideloadedApp(id: UUID(), name: "RetroArch", bundleIdentifier: "com.libretro.RetroArch", version: "1.19.1", iconSystemName: "arcade.stick.console", accent: .green, expiresAt: .now.addingTimeInterval(86400 * 6), status: .active, signingAccountID: nil)
        ]
    }

    func accounts() async throws -> [AppleAccount] {
        [AppleAccount(id: UUID(), email: "you@icloud.com", label: "Personal", isPrimary: true, appsInUse: 3, appLimit: 10)]
    }

    func refresh(app: SideloadedApp) async throws -> SideloadedApp {
        var updated = app
        updated.expiresAt = .now.addingTimeInterval(86400 * 7)
        updated.status = .active
        return updated
    }

    func refreshAll() async throws -> [SideloadedApp] {
        try await installedApps().asyncMap { try await refresh(app: $0) }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
