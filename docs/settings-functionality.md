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


## Update checks, account recovery and storage

The daily refresh App Intent and native background refresh callback both call `GitHubUpdateScanner`. It uses each app's selected token and update baseline, then posts notifications for newly detected builds. The shortcut scans before daily refresh deduplication and before attempting the local tunnel. Background execution remains subject to iOS; notification permission is required. Notification history prevents duplicate alerts for the same build after dismissal.

`SigningAccountStore` stores non-secret account/team metadata in the private `SigningAccounts.json` catalogue and keeps all session secrets in its existing Keychain vault. Known missing Core Data account/team records can be recovered; explicitly removed accounts stay removed. A failed read retains the last list, exposes retry, and offers sign-in recovery. Setup completion is persisted so a missing session later directs users to Accounts instead of treating every update as a first install. Different signing teams or app containers cannot inherit protected Keychain secrets.

Storage now counts the complete app container and any accessible App Group, including hidden files, allocated file sizes, database WALs, logs, caches and all temporary files. Folder pages expose the breakdown. Diagnostic output is capped at 5 MiB per active log and 10 MiB of retained older logs. Cleanup clears URL cache responses and retains the existing conservative orphan/pipeline pruning. iOS Storage accounting may differ or update later; device measurements are still needed to identify any remaining large directories.


## Free-account connection compatibility

The default connection method is external LocalDevVPN. Setup, install, refresh, re-sign, JIT and scheduled refresh all use the same connection service. External mode verifies a connected local `utun` interface before starting Minimuxer; it does not call the embedded VPN manager or stop another app's tunnel. The optional built-in mode is available on a separate Connection Method page only when both installed signatures and profiles grant Network Extension permission. An unsupported signature falls back to external mode.

CI packages `SideKick-unsigned.ipa` without a VPN extension or host VPN entitlement requests, preserving the existing default artifact name and free-account update source. `SideKick-vpn-unsigned.ipa` is a separate optional artifact. The in-app signing pipeline removes the optional SideKickVPN extension for a free team, and accepts the standard IPA without it. No paid-account requirement is imposed on ordinary SideKick installs or refreshes.
