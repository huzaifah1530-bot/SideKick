# Vendor support audit — 2026-10-12

Scope: Vendor/SideStore except AltStore, AltStore.xcodeproj, SideStore. Audit only. SideKick CI applies integration patches, builds the SideStore scheme, then removes AltWidget from both shipped IPAs. Widget issues below are retained-upstream issues, not shipped SideKick widget defects. Nested dependency sources are included in the coverage manifest. No production edits or external actions.

## VP-001 — P2 — Substring self-app identity clashes with distinct app IDs

Where: `Vendor/SideStore/Shared/Extensions/Bundle+AltStore.swift:112-115`; callers include `SideStore/Core/Operations/PipelineOperations/UninstallAppOperation.swift:28` and `CacheSigningCertOperation.swift:28`.

Why/what: `contains(activeID)` and `contains(altstoreID)` treat any identifier containing the store ID as the store itself. For example, `com.sidekick.app.helper` is classified as SideKick when the active bundle is `com.sidekick.app`. The integration patch changes the identity constant but leaves this predicate intact. This makes distinct apps enter self-app protections/signing/cache paths; uninstall refuses apps misclassified as self. This is a concrete identity clash rather than merely legacy naming.

Fix suggestion: Define one canonical self-identity predicate that compares the exact original ID and exact resigned ID (with a validated team suffix where appropriate), and use it across pipeline, certificate, and UI code. Do not accept arbitrary prefixes/suffixes or substring matches. Verify a helper ID containing SideKick's ID remains an ordinary app while the actual resigned SideKick remains protected.

## VP-002 — P2 — Top controller lookup skips a modal presented by the navigation/tab container

Where: `Vendor/SideStore/Shared/Extensions/UIApplication+AppExtension.swift:28-38`.

Why/what: The helper descends into UINavigationController/UITabBarController before checking `presentedViewController`. When a modal is presented by the container, it returns the underlying visible/selected child instead of the modal. Callers then try to present another flow from an offscreen controller, causing warnings or missing prompts. A nil selected child also restarts the lookup at the root because nil means default, creating recursion when a tab container has no selected controller.

Fix suggestion: Resolve the root once, check its presented controller first, then descend into non-nil navigation/tab children. Return the container when no child is available. Verify container-presented modal and empty-tab cases.

## VP-003 — P2 (retained upstream widget) — Pagination can force unwrap a missing state holder

Where: `Vendor/SideStore/AltWidget/Intents/PaginationIntent.swift:60-66`, `AltWidget/Providers/ActiveAppsTimelineProvider.swift:54-58`, `AltWidget/Manager/PageInfoManager.swift:14-15`.

Why/what: Page state exists only in process memory. After an extension restart, a pagination intent reads no previous event and stores a new event with a direction but nil `dataHolder`. The next provider update enters the direction branch and force unwraps that nil holder, crashing instead of changing page. A new dispatch queue for each intent does not persist or serialize shared page state; parallel instances can also mutate the dictionary concurrently.

Fix suggestion: Persist only a stable page index per widget in the shared container and update it through a single serialized state owner. At minimum, initialize a fresh holder whenever the saved holder is nil and avoid force unwraps. Exercise pagination immediately after extension termination and two widgets navigating concurrently. SideKick's packaging currently removes this extension, so this affects retained upstream widget builds.

## VP-004 — P3 (retained upstream widget) — Per-app countdown action refreshes every app

Where: `Vendor/SideStore/AltWidget/Widgets/ActiveAppsWidget.swift:175-185`, `AltWidget/Extensions/View+AltWidget.swift:43-50`, `AltWidget/Widgets/AppDetailWidget.swift:35-36`.

Why/what: A countdown visually belongs to one app, and descriptions say tap the countdown to refresh it/them. Every countdown is wrapped in `RefreshAllAppsWidgetIntent`, so selecting one app's timer starts a global refresh. This is surprising when other apps require input, fail signing, or consume refresh time.

Fix suggestion: Either expose a refresh-app intent carrying that app's canonical ID, or label the timer/action explicitly as Refresh All Apps and move it to a global control. Keep descriptions and accessibility labels aligned with the real scope. This remains dormant in the shipped SideKick IPAs because widgets are removed.

## VP-005 — P2 — First backup assumes an existing destination to replace

Where: `Vendor/SideStore/SideBackup/BackupEngine.swift:178-184,242-243,284-285`.

Why/what: Backup creates a unique temporary directory and copies the data successfully, then always calls `replaceItemAt(appBackupDirectory, ...)`. There is no branch to move the temporary backup into place when no prior backup exists. Foundation's replacement operation requires an original item; a new app's first backup can fail at the final step and the catch removes the newly copied temporary backup.

Fix suggestion: If the destination exists, replace it atomically; if absent, move the staged directory into the final destination. Keep both cases within the coordinated intent and only delete staging on true failure. Verify first backup, replacement backup, and simulated copy failure preserving the prior backup. This target remains upstream helper code; establish its packaging/re-signing use before prioritizing for SideKick.

## VP-006 — P1 — Copy retries can silently report success after copying nothing

Where: `Vendor/SideStore/SideBackup/BackupEngine.swift:456-479`, callers at `399-406`, final completion at `285-286,327`.

Why/what: For repeated file-exists errors, `copyItemRetrying` removes the conflicting destination and loops, but falls out of the retry loop without throwing or verifying a copy. On the final attempt, removal may even succeed and leave the destination absent; the caller still increments copied bytes and success count. Locking errors are also skipped by the caller regardless of `skipNonCopyable`, then the new backup replaces the prior backup and completion reaches 100%. Restore can therefore omit user data while being announced successful.

Fix suggestion: Track actual copy success, throw the last error on exhaustion, and return an explicit copied/skipped outcome for intentional skip mode. Make strict backup/restore abort on skipped items; partial backups must be identified and must not silently replace the last complete backup. Verify persistent file-exists/locking errors and final-attempt deletion outcomes.

## VP-007 — P2 — Overlapping backup requests overwrite the return context

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:58-66,74-88,191-209,236-276`.

Why/what: Each incoming backup/restore URL replaces the single `currentBackupReturnURL` and starts a task with no busy guard. A second request while the first is copying replaces the first callback, may launch restore concurrently, and the first completion clears the callback needed by the second operation. The caller can wait indefinitely and restore/backup can operate on changing data. Backgrounding also clears only UI state at 213-219 while work continues, allowing an inactive screen during active copying.

Fix suggestion: Serialize whole backup/restore operations and bind each operation to an immutable request ID and return URL. Reject or queue a second request explicitly. Retain a durable operation state through background transitions and clear it on completion, then deliver exactly one result for each accepted request.

## VP-008 — P2 — Failure callback discards the requested target bundle ID

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:101-105,124-134`.

Why/what: The failure branch replaces the return URL's complete query list with error fields. The subsequent target-app resolution reads `targetBundleID` from that now-replaced list, so failure callbacks lose a supplied target ID and fall back to inferred IDs. Success retains the query. This makes the route back to the caller differ precisely on errors when reliable recovery is needed.

Fix suggestion: Resolve and retain the target bundle ID from the original request before editing the callback, or merge error fields into existing query items. Verify success/failure both launch the same explicitly selected caller.

## VP-009 — P2 — Recoverable operation error permanently becomes a boot failure

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:236-241,262-267,288-291`; `SideBackup/ContentView.swift:20-35`.

Why/what: Every backup/restore failure is assigned to `bootCheckError`. Both future operations short-circuit on this property, and the screen says SideBackup could not start. A transient copy error therefore prevents retry until the process restarts and presents an inaccurate startup error. The `errorTitle` argument is unused.

Fix suggestion: Keep immutable startup entitlement/container failures separate from operation failures, reset operation status on completion, display the correct operation-specific error, and allow a retry after a recoverable failure.

## VP-010 — P3 — Contribution setup still requires removed dependency tooling

Where: `Vendor/SideStore/CONTRIBUTING.md:44-59,70-73` versus `Vendor/SideStore/AGENTS.md:17-20,58` and `.gitmodules:3-10`.

Why/what: CONTRIBUTING instructs contributors to run CocoaPods and `SideStore/fetch-prebuilt.sh`, says minimuxer is built from Rust, and warns about Cargo paths. The checked-out project uses Swift packages/pure Swift minimuxer, has no tracked Podfile or fetch-prebuilt.sh, and AGENTS describes the newer setup. Following the older contributor flow hits missing-file/setup failures and adds unnecessary tools.

Fix suggestion: Replace obsolete setup sections with the actual recursive-submodule/SPM workflow and minimum Xcode requirements; link SideKick contributors to the root patch/build workflow so they understand vendored versus integrated builds. Keep only documentation that matches commands present in the tree.

## VP-011 — P3 — Signing sample contains unrelated project identifiers and missing instructions

Where: `Vendor/SideStore/CodeSigning.xcconfig.sample:14-18,38-53`.

Why/what: The copy-and-customize signing sample tells users to register Provenance IDs, describes UTM hypervisor provisioning, and references nonexistent Documentation/MacDevelopment.md and Provenance/macOS.entitlements. This clashes with the actual SideStore iOS/tvOS targets and misdirects new contributors during signing setup.

Fix suggestion: Remove unrelated macOS/UTM/Provenance sections and document the actual SideStore main/helper/widget identifiers generated by Build.xcconfig. Provide separate free/paid examples that agree with DEVELOPER_ACCOUNT_PAID and chosen entitlements.

## VP-012 — P3 — Legacy QA/setup targets reference absent tooling

Where: `Vendor/SideStore/Makefile:78-81,112-124,145-155`.

Why/what: `pull_request` invokes Fastlane, Danger and the retired Codecov curl script; bundler setup is for version 1.17. No tracked Gemfile, Fastfile, Dangerfile, or supporting configuration exists in this checkout. These targets sit alongside functional xcodebuild test targets, creating two competing development workflows; selecting the older advertised targets fails rather than validating the code.

Fix suggestion: Remove unused legacy Ruby QA targets and unused RUBY/BUNDLER checks, or restore explicit maintained configuration if the project still needs them. Point help/development instructions at the working Swift/Xcode test path. Root SideKick CI uses its own direct build and does not run these legacy targets.

## VP-013 — P2 (upstream CI path) — Test/package pipelines hide failed commands

Where: `Vendor/SideStore/scripts/ci/workflow.py:149-150,157-162,204-211`.

Why/what: Only the main build pipeline requests pipefail. Test build, test run, fakesign and IPA commands pipe output to tee/xcbeautify without it. Shell success is the last pipeline command's status, so a failed xcodebuild/make step can be treated as successful and CI continues to archive results or publish artifacts. These vendor workflows are dormant inside SideKick's submodule; root CI runs its own tests/build with stricter failure handling.

Fix suggestion: Invoke subprocess pipelines through an explicit Bash shell with pipefail for every pipeline, or run commands directly and capture output without a shell pipeline. Verify deliberately failing test, signing and packaging commands make their wrapper and CI step fail.

## VP-014 — P2 — Readiness hardcodes Wi-Fi even for remote/wired connections

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerImpl.swift:117-125,128-152`.

Why/what: The shared readiness gate rejects every path unless `network.isWifiSatisfied`; wired/USB/bridge alternatives are commented out. This happens before checking localVPN versus remoteServer. A reachable remote endpoint over Ethernet or an external VPN/cellular route is therefore reported as No wifi interface satisfied even when the selected connection mode and endpoint work. It clashes with the public remote-server connection option and published network capability flags.

Fix suggestion: Apply prerequisites by connection mode and actual route requirements. Keep any necessary on-device local VPN restrictions explicit; for remoteServer validate endpoint reachability on its available path rather than requiring Wi-Fi globally. Verify working remote endpoint over wired and external-VPN routes, plus Wi-Fi disconnection handling.

## VP-015 — P2 — Dead heartbeat service remains wired into the composition root

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerApi.swift:270,282`, `Sources/MinimuxerImpl.swift:36,51,61`, `Sources/Services/HeartbeatService.swift:58-82`.

Why/what: The composition root creates and retains HeartbeatService, but no production call to heartbeat.start/stop exists anywhere in the dependency. Its lifecycle/status fields never participate in readiness, and the implementation never starts a keepalive. This is dead service wiring that suggests a capability the library does not activate; it also leaves an unchecked stop-insensitive waiting loop for any future reuse.

Fix suggestion: Establish whether gateway.performHeartbeat is intentionally unused. If redundant with backend connection keepalive, remove the service and injected references; if required, integrate explicit start/stop ownership after gateway startup and stop-sensitive waiting. Avoid retaining a nonfunctional lifecycle service.

## VP-016 — P1 — IPv6 sockaddr is truncated before passing its original length to getnameinfo

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/NetworkIfaceScanner.swift:31-35,285-298,640-649`.

Why/what: IPv6 addresses are copied using `.pointee` from `UnsafePointer<sockaddr>`, which yields a 16-byte sockaddr value. `sockaddrIPv6` then passes `sa.sa_len` (normally 28 for sockaddr_in6) with the address of that 16-byte local value to getnameinfo. It reads beyond the copied value instead of the full IPv6 address. Scanning IPv6 interfaces/routes can therefore return corrupt addresses or access adjacent stack memory. This is in the live network discovery dependency, not just diagnostic code.

Fix suggestion: Preserve the original pointer and its validated length, then rebound/read sockaddr_in6 for AF_INET6 or pass the original full buffer to getnameinfo. Never copy a variable-sized sockaddr into the base struct. Verify IPv6 and scoped link-local interface/route records with address sanitization on an Apple platform.

## VP-017 — P1 — Fake local usbmux listener binds all interfaces and serves pairing credentials

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/UsbmuxdProxyServer.swift:48,64-67,236-240`.

Why/what: The comment promises 127.0.0.1:27015, but `NWListener(using: .tcp, on: port)` has no loopback `requiredLocalEndpoint` and accepts connections on available interfaces. The unauthenticated ReadPairRecord message returns the complete pairing file, including pairing credentials, to any connecting client. This clashes with the intended local-only helper and can expose credentials on a reachable LAN when the libimobiledevice backend activates it.

Fix suggestion: Require a loopback local endpoint in NWParameters before constructing the listener, reject nonloopback peers as defense in depth, and scope supported packet requests. Verify loopback access works and LAN IPv4/IPv6 access is rejected. Do not rely on the documentation comment as a bind restriction.

## VP-018 — P2 — Restarting network observation reuses a cancelled monitor

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/NetworkObserverService.swift:25,49-70,168-180`.

Why/what: stop cancels the sole NWPathMonitor and sets started=false; a later start calls start on that same cancelled monitor. NWPathMonitor cancellation is terminal, so the public stop/start lifecycle cannot restore network observation, leaving reachability/UI updates stale. Separate actor read and write also permit concurrent starts to both pass the alreadyStarted guard.

Fix suggestion: Own a new monitor per observation session, atomically transition stopped to starting, and finish/cancel the old stream and handler during stop. Verify stop/start receives new path changes and concurrent start callers produce one observer.

## VP-019 — P2 — Cancelled wireless-pair task clears and stops its replacement

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/WirelessPairService.swift:45-50,90-100,116-120,156-165`.

Why/what: Starting a replacement cancels the old task and stores the new one. When the old task finishes/catches cancellation, its cleanup unconditionally sets activeStartTask=nil and stops shared advertising; trigger cleanup likewise removes whatever task is currently stored under the socket key. A cancelled old session therefore erases the replacement's tracking and may shut down its advertisement. Further Stop/replacement actions can miss the new work and UI receives stale completion events.

Fix suggestion: Assign a generation/request token to each task and only clear the slot, stop that session's advertisement, or deliver completion if it is still the active generation. Await teardown before starting shared resources. Verify rapid Start-Start, Trigger-Trigger on one target, and Stop-Start flows.

## VP-020 — P2 — Stop wireless pairing cannot interrupt blocking accept

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift:1891-1896`, `Common/TCPAcceptor.swift:57-64`, `Sources/Services/WirelessPairService.swift:169-184`, `Common/FFIDispatcher.swift:19-27`.

Why/what: The host pairing task waits in blocking Darwin.accept on a socket local to syncStartWirelessPair. Stop only cancels the Swift task; withFFIDispatch does not propagate cancellation, and nothing closes the accept socket. Cancelling the pairing screen before any peer connects leaves the GCD thread, pairing handle and task alive indefinitely. Repeated attempts accumulate waiting sessions and can produce late callbacks.

Fix suggestion: Own the acceptor in a cancellable session, close/shutdown its socket when the request is cancelled, or use a nonblocking/poll loop with bounded waits and cancellation checks. Pairing handshake and PIN waits should use the same cancellation token. Verify cancelling before a peer connects completes promptly without late PIN/completion events.

## VP-021 — P1 — Concurrent gateway calls race cached native pointer destruction

Where: `Vendor/SideStore/Dependencies/minimuxer/Common/FFIDispatcher.swift:15-20`; `DeviceGateway/idevice/IdeviceGateway.swift:75-77,110-118,242-246,2296-2310`; `DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:79-83,173-187`.

Why/what: All async gateway methods dispatch synchronous work to the default global concurrent queue. Cached pairing/tunnel/adapter/handshake pointers and gateway state are mutable and unprotected. Network endpoint changes call invalidateConnection directly, freeing these native handles, while concurrent service actions can be using them. Two ensureConnection calls may also create/overwrite caches concurrently. @unchecked Sendable does not provide synchronization. This risks native use-after-free/double-free and intermittent installs/JIT failures.

Fix suggestion: Give each gateway a serial native-operation executor and ensure start/stop/invalidation/state setters run through the same ownership boundary. Keep blocking pairing accept/PIN sessions separately cancellable so they cannot monopolize that executor. Alternatively, use explicit handle leases/refcount ownership with synchronized cache replacement. Verify simultaneous readiness/installation and endpoint invalidation under Thread/Address Sanitizer.

## VP-022 — P2 — Container wipe suppresses all removal errors

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift:2266-2272,2275-2285`.

Why/what: afcRemovePathRecursive is declared throwing but a failed afc_remove_path only logs and frees the error, then returns success. wipeContainer consequently announces completion even when files/directories remain. This makes its reset flow unreliable and can leave old data mixed with a subsequent restore/reinstallation.

Fix suggestion: Throw an error identifying the failed remote path, or return an explicit partial result requiring UI acknowledgement. Only announce a complete wipe once every intended item is removed. Verify denied/busy file removal is reported to the caller.

## VP-023 — P2 — Libimobiledevice Remote Pairing initializes without the UDID required by every operation

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:134-136,375-400,405-406`.

Why/what: cleanup clears cachedUDID. Remote Pairing startup sets rpIdentity but only the lockdown branch assigns cachedUDID. verifyInitialized nevertheless requires cachedUDID for both modes. First fetchUDID calls verifyInitialized before it can populate the cache, so the Remote Pairing backend remains permanently NotInitialized despite successful startup. withRPClient also hits this guard.

Fix suggestion: Validate initialization according to the selected protocol: a valid RP identity for Remote Pairing and a valid UDID for lockdown. Resolve/cache the live RP UDID after establishing the tunnel without depending on the very cache being resolved. Verify the full startup/readiness/installation flow for each backend/protocol combination.

## VP-024 — P2 — Libimobiledevice lockdown DDI mounting never uploads the supplied image

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:518-543,596-623`.

Why/what: The lockdown mount functions receive image Data but directly request mounting `/tmp/DeveloperDiskImage.dmg` or `/tmp/PersonalizedImage.dmg`, without sending that image to the device. The personalized helper is explicitly a placeholder and does not use its image parameter. Unlike the idevice implementation's upload-then-mount path, a clean device has no staged image at those hardcoded paths and mounting fails.

Fix suggestion: Implement a real upload/staging and required personalization sequence for lockdown, or make the unsupported backend/protocol combinations explicit before the user chooses them. Verify on a device without any pre-staged DDI.

## VP-025 — P2 — Libimobiledevice profile dump returns XML where callers require a filesystem path

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:709-729`; `Sources/MinimuxerImpl.swift:497-502`.

Why/what: The lockdown profile dump returns the serialized XML response string, while its API and the idevice/RP paths return a directory. ZIP mode treats that XML as a filesystem path and tries to zip it, causing export failure. Writes in the other dump paths use try? and can silently return an empty/incomplete directory as successful.

Fix suggestion: Normalize all backends to write the returned profiles into the requested dump directory, return that directory path, and propagate write failures. Define a structured result if raw data export is separately required. Verify raw and ZIP exports for both backends and denied/full-disk destinations.

## VP-026 — P2 — Libimobiledevice container wipe is a successful no-op

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1130-1160`.

Why/what: Both protocol branches only ask House Arrest to vend the app container, then close the service. Neither lists nor deletes any files. The Remote Pairing branch also ignores the response error. A caller requesting reset receives success while all app data remains. This is distinct from the idevice backend removal-error suppression in VP-022.

Fix suggestion: After validating the House Arrest response, obtain an AFC client for that container and recursively remove the intended contents, propagating failed removals. If this backend cannot implement wiping, return unsupportedOperation and prevent a misleading successful reset. Verify a seeded container is actually emptied for both protocols.

## VP-027 — P2 — Remote Pairing debug operations report success without attaching

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1196-1202,1231-1236`.

Why/what: Remote Pairing debugApp/debugProcess only connect to debugserver and log the requested identifier/PID; they never send a process lookup, attach, or detach command. The caller sees a completed JIT enable operation with no debugger action. VP-023 currently prevents this mode reaching the operation; fixing initialization alone exposes this additional incomplete implementation.

Fix suggestion: Implement the Remote Pairing debugserver protocol and validate responses through attachment/detachment, matching the lockdown branch's intended behavior. Until supported, throw a specific unsupported-operation error and reflect availability in the backend picker.

## VP-028 — P2 — Libimobiledevice app file APIs ignore their app identifier

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1299-1306,1328-1335,1361-1368`.

Why/what: All three app file methods accept bundleId but never use it. They connect to ordinary AFC, whose filesystem is the shared media service rather than the selected app's House Arrest container. Compared with the idevice implementation's container session, listing/reading/stat-ing an app path can show unrelated media contents or fail despite the requested app file existing.

Fix suggestion: Vend the specified app container with House Arrest, validate the response, and use the resulting AFC connection for all three operations. Share a scoped container-client helper to keep backend semantics consistent. Verify two apps containing different same-named files return their own contents.

## VP-029 — P2 — Lockdown uploads discard the reported write length

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:913-922,1065-1077`.

Why/what: IPA and app bundle uploads send each entire buffer with one afc_file_write and ignore bytesWritten. A successful short write is therefore reported as a completed upload, followed by installing a partial package. UInt32(data.count) also traps for files larger than its range. App bundle empty files skip writing altogether even if an old staged file already exists.

Fix suggestion: Upload bounded chunks until the complete buffer has been acknowledged, reject zero-progress writes, and propagate errors with the path/offset. Explicitly truncate or recreate every staged destination, including empty files, and clean stale staged app content before reuse. Verify forced short writes and uploading a smaller/empty replacement file.
