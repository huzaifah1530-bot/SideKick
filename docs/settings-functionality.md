# Ported settings functionality

This audit follows each SideKick control to the pinned SideStore implementation. These are code-level connections; signing, networking, permissions, background execution, and file migration still require physical-device validation.

| Control | Runtime connection and behavior |
| --- | --- |
| Automatic app refresh | `isBackgroundRefreshEnabled` gates `AppDelegate.performBackgroundFetch`. The bootstrap and toggle set the minimum background-fetch interval. iOS chooses when to run it; it does not check GitHub. |
| Keep SideKick active during refresh | `PipelineRunner.perform` reads `isIdleTimeoutDisableEnabled`, disables the screen idle timer during operations, and restores it afterward. |
| Refresh over cellular | `CellularRefreshManager` reads `isCellularRefreshEnabled`. Send/refresh operations invoke the configured data-off/data-on shortcuts around the device connection. The new shortcut page edits the names the manager consumes. A VPN and correctly configured shortcuts are still required. |
| Keep-alive enabled and method | Calls `BackgroundServiceManager.setEnabled` and `switchTo`. Changing the method explicitly stops the prior service before starting the new one. Location uses iOS location permission; the page shows a Settings link when access is denied. |
| Confirm before installing | `InstallConsoleView` reads `isInstallConfirmationEnabled` before SideKick's own install/update begins. SideStore's deep-link install dialog also reads it. |
| Open app after installation | `AppManager.install` checks `isAutoLaunchAppAfterInstallEnabled` after successful installation and opens the installed app's URL. It excludes SideKick itself. |
| Clear customizations after uninstall | `CacheResignedMetadataOperation.clearCustomizations` reads `isClearCustomizationsOnUninstallEnabled` in the removal pipeline. Removing an imported IPA is not an uninstall and does not invoke this option. |
| Prefer the resigned IPA | `CreateIpaOperation`, `SendAppOperation`, and `InstallAppOperation` read `preferResignedIPA` to choose IPA or bundle installation. |
| Save resigned apps | `ExportResignedIpaOperation` reads `isExportResignedAppEnabled` and saves a copy in Documents/ResignedApps, replacing the same app's existing export. These user-requested copies are counted in Storage and kept by cleanup. |
| Disable app limit | `InstalledApp` and `AppManager` read `isAppLimitDisabled`; the setting is disabled when the pinned engine reports neither MacDirtyCow nor sparseRestore support. It cannot bypass Apple limits on unsupported iOS versions. |
| Local Connection | `LocalVPNService` manages an embedded `NETunnelProviderManager` configuration, checks host/extension signatures and profiles, and acquires/releases a shared operation connection. Its settings page requests iOS permission, verifies pairing over a temporary connection, and removes the configuration. The provider closes itself after 90 seconds without a heartbeat. |
| Pairing-port retry | Minimuxer port discovery reads `isAutoRetryRemotePairingPortEnabled`. |
| Remote pairing port | Updates `remotePairingPortOverride` and synchronizes the live Minimuxer backend. |
| Local addresses | The embedded tunnel uses the upstream fixed IPv4 peer/interface. An IPv6 input-acceptance toggle is not shown because this page no longer exposes a custom address editor. |
| Import pairing file | `PairingSetupImporter` imports the trust record, `AppBootManager` restarts Minimuxer, and a live UDID probe updates the verified setup state. |
| On-device Anisette | `AnisetteProvider.fetch` reads `useOnDeviceAnisette` for the next authentication request. |
| Servers & Server Lists | Uses `AnisetteServersView`, which edits `AnisetteServersManager`'s catalogue, selects servers, syncs a remote source, and imports saved lists. Remote authentication consumes this catalogue. The prior standalone URL fields and unused authentication Offline mode toggle were removed. Catalogue file/offline mode is handled by the working server manager page. |
| Storage | Lists imported copies and actual signing/temporary/export directories. Cleanup removes unused payloads, orphaned downloaded IPA copies, and abandoned staging files; it keeps installed records, current signing sources, and exported IPAs. |
| GitHub tokens | Named tokens are validated and kept in Keychain. Each app can select a default token and each GitHub download can override it. GitHub repository, Contents, and Actions permissions still determine access. |

The integration patch also cleans pipeline staging in a `defer` so an error or cancellation does not bypass the success-only cleanup step. Owned staging directories record their process ID, allowing startup cleanup to distinguish abandoned work from operations in the current process.
