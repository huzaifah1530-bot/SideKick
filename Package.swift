// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideKickCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SideKickCore", targets: ["SideKickCore"])],
    targets: [
        .target(name: "SideKickCore", path: "SideKick", exclude: [
            "App", "Assets.xcassets", "Brand", "Components", "DesignSystem", "ViewModels", "Views", "Info.plist",
            "Services/AppSharingService.swift", "Services/DailyRefreshShortcut.swift", "Services/ExpirationNotificationScheduler.swift",
            "Services/GitHubCredentialStore.swift", "Services/GitHubUpdateDownloadStore.swift", "Services/GitHubUpdateNotificationScheduler.swift",
            "Services/GitHubUpdateScanner.swift", "Services/GitHubUpdateService.swift", "Services/IPAImportStore.swift", "Services/LocalVPNService.swift",
            "Services/PairingSetupImporter.swift", "Services/ProgressFileDownload.swift", "Services/SideKickCertificateExport.swift",
            "Services/SideKickDataDirectory.swift", "Services/SideKickLogStorage.swift", "Services/SideKickStorageUsage.swift",
            "Services/SideStoreOperationService.swift", "Services/SigningAccountStore.swift", "Services/SigningExpiry.swift",
            "Services/NativeAppTransferService.swift", "Services/SideKickDiagnostics.swift"
        ], sources: [
            "Models/GitHubBuildTracking.swift",
            "Models/ImportedIPA.swift",
            "Models/LiveContainerModels.swift",
            "Models/GitHubUpdateConfiguration.swift",
            "Services/GitHubHistoryClient.swift",
            "Services/GitHubHistoryStore.swift",
            "Services/GitHubDiagnosticsStore.swift",
            "Services/DiagnosticsStore.swift",
            "Services/UnsavedSettingsCoordinator.swift",
            "Services/GitHubUpdateDiscovery.swift",
            "Services/AnisetteConfiguration.swift",
            "Services/LiveContainerScanner.swift",
            "Services/LiveContainerStore.swift",
            "Services/GitHubUpdateConfigurationStore.swift",
            "Services/SideKickStorageCleanup.swift",
            "Services/AppDataTransfer.swift",
            "Services/AppCredentialTransfer.swift",
            "Services/AppCredentialSigningPolicy.swift",
            "Services/SystemAppCredentialStore.swift"
        ]),
        .testTarget(name: "SideKickCoreTests", dependencies: ["SideKickCore"], path: "Tests/SideKickCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
