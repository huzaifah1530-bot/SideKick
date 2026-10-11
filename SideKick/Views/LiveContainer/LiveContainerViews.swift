import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LiveContainerLibrarySection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedGuestID: String?
    @State private var isShowingGuestDetail = false
    @State private var workingGuestID: String?
    @State private var actionError: String?
    private var state: LiveContainerState { environment.liveContainerState }
    private var message: String? { environment.liveContainerLoadError }

    var body: some View {
        Section {
            ForEach(state.apps) { app in
                NavigationLink {
                    LiveContainerGuestDetailView(guestID: app.id)
                } label: {
                    HStack(spacing: 12) {
                        LiveContainerGuestIcon(data: app.iconData).frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.body.weight(.semibold))
                            Text("\(app.version) · Build \(app.build)").font(.subheadline).foregroundStyle(.secondary)
                            if let connection = state.connections.first(where: { $0.id == app.connectionID }) {
                                Text(connection.storageKind == .snapshot ? "Snapshot · \(connection.name)" : connection.name)
                                    .font(.caption).foregroundStyle(.secondary)
                                if !connection.isConnected || connection.error != nil {
                                    Text("Reconnect to scan").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if !app.isAvailable { Text("Unavailable · previous metadata").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    SwiftUI.Button {
                        selectedGuestID = app.id
                        isShowingGuestDetail = true
                    } label: {
                        Label("More Options", systemImage: "ellipsis.circle")
                    }
                    SwiftUI.Button {
                        Task { await launch(app) }
                    } label: {
                        Label("Launch", systemImage: "play.circle")
                    }
                    .disabled(workingGuestID != nil || !canLaunch(app))
                    SwiftUI.Button {
                        Task { await refresh(app) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(workingGuestID != nil || connection(for: app)?.isConnected != true)
                }
                .fullWidthListSeparators()
            }
            if let message {
                Label(state.apps.isEmpty ? "Couldn’t Load LiveContainer Apps" : "Some LiveContainer Apps May Be Outdated", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Try Again") { Task { await environment.reloadLiveContainerCatalogue() } }
                    .disabled(environment.isLoadingLiveContainerCatalogue)
            } else if !environment.hasLoadedLiveContainerCatalogue {
                HStack {
                    ProgressView("Loading LiveContainer apps…")
                    Spacer()
                }
            } else if state.apps.isEmpty {
                Text("No cached guest apps were found.")
                    .foregroundStyle(.secondary)
                NavigationLink { LiveContainerConnectionsView() } label: {
                    Label("Manage Connections", systemImage: "folder")
                }
            }
        } header: { Text("LiveContainer") }
        .navigationDestination(isPresented: $isShowingGuestDetail) {
            if let selectedGuestID {
                LiveContainerGuestDetailView(guestID: selectedGuestID)
            }
        }
        .alert("LiveContainer", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func connection(for app: LiveContainerGuest) -> LiveContainerConnection? {
        state.connections.first(where: { $0.id == app.connectionID })
    }

    private func canLaunch(_ app: LiveContainerGuest) -> Bool {
        guard let connection = connection(for: app) else { return false }
        return app.isAvailable && app.warning == nil && connection.isConnected
            && connection.error == nil && connection.storageKind != .snapshot
    }

    @MainActor private func launch(_ app: LiveContainerGuest) async {
        guard workingGuestID == nil else { return }
        guard canLaunch(app) else {
            actionError = "Reconnect this LiveContainer directory and make sure the guest is available before launching it."
            return
        }
        workingGuestID = app.id
        defer { workingGuestID = nil }
        do {
            let url = try await environment.liveContainerStore.launchURL(for: app.id)
            guard await UIApplication.shared.open(url) else {
                actionError = "LiveContainer did not accept the launch request. Check its installation and URL scheme."
                return
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor private func refresh(_ app: LiveContainerGuest) async {
        guard workingGuestID == nil else { return }
        guard let connection = connection(for: app), connection.isConnected else {
            actionError = "Reconnect this LiveContainer directory before refreshing the guest."
            return
        }
        workingGuestID = app.id
        defer { workingGuestID = nil }
        do {
            try await environment.liveContainerStore.rescan(connection.id)
            await environment.reloadLiveContainerCatalogue()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct LiveContainerConnectionsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var state = LiveContainerState()
    @State private var picker = false
    @State private var name = "LiveContainer"
    @State private var scheme = "livecontainer"
    @State private var kind: LiveContainerStorageKind = .privateDocuments
    @State private var reconnectID: UUID?
    @State private var isWorking = false
    @State private var error: String?
    @State private var forgetting: LiveContainerConnection?

    var body: some View {
        List {
            Section {
                TextField("Connection name", text: $name)
                Picker("Directory type", selection: $kind) {
                    ForEach(LiveContainerStorageKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("URL scheme", text: $scheme).textInputAutocapitalization(.never).autocorrectionDisabled()
                SwiftUI.Button { reconnectID = nil; picker = true } label: {
                    Label("Link Applications Directory", systemImage: "folder.badge.plus")
                }
                .disabled(isWorking)
            } header: { Text("Link LiveContainer") } footer: {
                Text("Select the actual Applications directory under Files → On My iPhone → LiveContainer. Shared App Group storage works only if it is exposed by a file provider. SideKick cannot unlock private storage. Use livecontainer, livecontainer2, or the scheme configured for your installation. An exported copy is a snapshot; it cannot verify installed versions or launch guests.")
            }
            if isWorking { Section { ProgressView("Reading directory…") } }
            if state.connections.isEmpty { Section { ContentUnavailableView("No Linked Directories", systemImage: "folder") } }
            ForEach(state.connections) { connection in
                Section {
                    LabeledContent("Storage", value: connection.storageKind.title)
                    LabeledContent("Launch scheme", value: connection.scheme)
                    LabeledContent("Access", value: connection.isConnected ? (connection.error == nil ? "Linked" : "Needs attention") : "Disconnected")
                    if let date = connection.lastSuccessfulScan { LabeledContent("Last successful scan", value: date.formatted()) }
                    if let error = connection.error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                    ForEach(Array(connection.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.footnote).foregroundStyle(.secondary) }
                    SwiftUI.Button { Task { await run { try await environment.liveContainerStore.rescan(connection.id) } } } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking || !connection.isConnected)
                    SwiftUI.Button {
                        reconnectID = connection.id; name = connection.name; scheme = connection.scheme; kind = connection.storageKind; picker = true
                    } label: { Label("Reconnect Directory", systemImage: "folder") }
                    .disabled(isWorking)
                    SwiftUI.Button {
                        reconnectID = nil; name = connection.name; scheme = connection.scheme; kind = connection.storageKind; picker = true
                    } label: { Label("Select a Different Directory", systemImage: "folder.badge.plus") }
                    .disabled(isWorking)
                    if connection.isConnected {
                        SwiftUI.Button("Disconnect") { Task { await run { try await environment.liveContainerStore.disconnect(connection.id) } } }
                            .disabled(isWorking)
                    }
                    SwiftUI.Button("Forget Connection", role: .destructive) { forgetting = connection }.disabled(isWorking)
                } header: { Text(connection.name) } footer: {
                    Text("Disconnect keeps discovered metadata and GitHub sources. Selecting a different directory adds a separate connection; disconnect the old one when finished. Forget removes SideKick’s catalogue and source settings only. Guest files are never changed.")
                }
            }
        }
        .navigationTitle("LiveContainer")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerDidChange)) { _ in Task { await reload() } }
        .refreshable { await reload() }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
            Task {
                await run {
                    let url = try result.get()
                    try await environment.liveContainerStore.link(directory: url, name: name, scheme: scheme, storageKind: kind, replacing: reconnectID)
                }
            }
        }
        .alert("LiveContainer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .alert("Forget this connection?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            SwiftUI.Button("Forget", role: .destructive) {
                guard let connection = forgetting else { return }
                forgetting = nil
                Task { await run {
                    let ids = try await environment.liveContainerStore.forget(connection.id)
                    for id in ids { try await GitHubUpdateConfigurationStore.shared.remove(bundleIdentifier: id) }
                } }
            }
            SwiftUI.Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text("Cached guest metadata and GitHub associations will be removed from SideKick. LiveContainer’s files remain in place.") }
    }

    @MainActor private func reload() async {
        do { state = try await environment.liveContainerStore.snapshot() } catch { self.error = error.localizedDescription }
    }
    @MainActor private func run(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await operation(); await reload() } catch { self.error = error.localizedDescription; await reload() }
    }
}

struct LiveContainerGuestDetailView: View {
    let guestID: String
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var guest: LiveContainerGuest?
    @State private var connection: LiveContainerConnection?
    @State private var hasChecked = false
    @State private var checkFailed = false
    @State private var candidate: GitHubUpdateCandidate?
    @State private var configuration: GitHubUpdateConfiguration?
    @State private var working = false
    @State private var isCheckingUpdates = false
    @State private var updateCheckGeneration = UUID()
    @State private var updateCheckRequested = false
    @State private var message: String?
    @State private var markingInstalled = false
    @State private var confirmingGuestRemoval = false
    @State private var checkState: GitHubCheckState = .notConfigured
    @State private var awaitingHandoff: String?
    @State private var sharedIPA: LiveContainerSharedIPA?
    @State private var handoffURL: URL?

    private var downloadJob: GitHubUpdateDownloadJob? {
        candidate.flatMap { environment.githubUpdateDownloads.jobs[$0.id] }
    }

    private var canCheckUpdates: Bool {
        guard let guest = self.guest else { return false }
        return connection?.isConnected == true && connection?.error == nil
            && connection?.storageKind != .snapshot && guest.isAvailable && guest.warning == nil
    }

    private var updateEligibilityMessage: String {
        guard let connection else { return "Reconnect LiveContainer before updating this guest." }
        if !connection.isConnected || connection.error != nil {
            return "Reconnect the LiveContainer Applications folder and rescan before updating this guest."
        }
        if connection.storageKind == .snapshot {
            return "Link a live LiveContainer Applications folder in Files before updating a guest."
        }
        if guest?.isAvailable != true || guest?.warning != nil {
            return "Rescan the LiveContainer Applications folder and resolve the guest warning before updating."
        }
        return "This guest is unavailable for update handoff. Check its LiveContainer connection."
    }

    var body: some View {
        List {
            if let guest {
                Section {
                    HStack(spacing: 16) {
                        LiveContainerGuestIcon(data: guest.iconData).frame(width: 76, height: 76)
                        VStack(alignment: .leading) {
                            Text(guest.name).font(.title3.bold())
                            Text("\(guest.version) · Build \(guest.build)").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section {
                    SwiftUI.Button { Task { await launch() } } label: { Label("Open in LiveContainer", systemImage: "play.circle") }
                        .disabled(working || connection?.isConnected != true || connection?.storageKind == .snapshot || !guest.isAvailable || guest.warning != nil)
                    if let connection {
                        SwiftUI.Button { Task { await openContainer(connection) } } label: { Label("Open LiveContainer", systemImage: "square.stack.3d.up") }
                    }
                } footer: { Text("SideKick requests a launch. LiveContainer handles authentication, JIT, and errors; accepting a URL does not confirm that the guest started.") }
                Section("GitHub Updates") {
                    NavigationLink { GitHubUpdateSettingsView(target: guest.updateTarget) } label: {
                        Label("Update Source & Installed Build", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    SwiftUI.Button { Task { await checkUpdates() } } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                        .disabled(working || isCheckingUpdates || connection?.isConnected != true || connection?.error != nil || connection?.storageKind == .snapshot || !guest.isAvailable || guest.warning != nil)
                    if let configuration {
                        LiveContainerInstalledBuildDisclosure(configuration: configuration)
                            .id(configuration.sourceIdentity + "\n" + (configuration.effectiveBaselineKey ?? ""))
                    }
                    if let candidate {
                        SwiftUI.Button { Task { await updateInLiveContainer(candidate) } } label: {
                            Label(downloadJob?.isDownloading == true ? "Downloading IPA…" : "Update in LiveContainer", systemImage: "arrow.down.app")
                        }
                        .disabled(working || isCheckingUpdates || !canCheckUpdates || downloadJob?.isDownloading == true)
                        if !canCheckUpdates {
                            Label(updateEligibilityMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if let progress = downloadJob?.progress, downloadJob?.isDownloading == true { ProgressView(value: progress) }
                        if let error = downloadJob?.errorMessage { Text(error).foregroundStyle(.orange) }
                        LabeledContent("Available", value: candidate.newVersion)
                        if let url = URL(string: candidate.repositoryURL ?? "https://github.com") {
                            Link(destination: url) { Label("View on GitHub", systemImage: "arrow.up.right.square") }
                        }
                        SwiftUI.Button { markingInstalled = true } label: { Label("Already Installed This Build", systemImage: "checkmark.circle") }
                            .disabled(working || isCheckingUpdates)
                        SwiftUI.Button { Task { await resolve(markInstalled: false) } } label: { Label("Skip This Build", systemImage: "forward.end") }
                            .disabled(working || isCheckingUpdates)
                        Text("Update downloads the IPA, then opens the share sheet. Choose LiveContainer to start installing it. Confirm this build after installation finishes.").font(.footnote).foregroundStyle(.secondary)
                    } else if configuration != nil { Text(hasChecked ? checkState.message : "Check this source for newer builds.").foregroundStyle(.secondary) }
                    if isCheckingUpdates { ProgressView("Checking for updates…") }
                    else if working { ProgressView() }
                }
                Section("LiveContainer Details") {
                    LabeledContent("Bundle ID", value: guest.bundleIdentifier).textSelection(.enabled)
                    LabeledContent("App folder", value: guest.folder).textSelection(.enabled)
                    LabeledContent("Last seen", value: guest.lastSeen.formatted())
                    LabeledContent("Connection", value: connection?.name ?? "Missing")
                    if let connection { LabeledContent("Storage", value: connection.storageKind.title) }
                    if let warning = guest.warning { Text(warning).foregroundStyle(.orange) }
                    if let error = connection?.error { Text(error).foregroundStyle(.orange) }
                    NavigationLink { LiveContainerConnectionsView() } label: { Label("Connection & Rescan", systemImage: "folder") }
                    if !guest.isAvailable {
                        SwiftUI.Button("Remove Cached Guest", role: .destructive) {
                            confirmingGuestRemoval = true
                        }
                        .disabled(working || isCheckingUpdates)
                    }
                }
            } else { ContentUnavailableView("Guest Not Found", systemImage: "app.dashed") }
        }
        .navigationTitle(guest?.name ?? "LiveContainer Guest")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload(); await checkUpdates() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerDidChange)) { _ in
            Task { await reloadAfterCatalogueChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            invalidateUpdateCheck()
            Task { await reload(); await checkUpdates(force: true) }
        }
        .onChange(of: downloadJob?.queuedIPA) { _, ipa in
            if let ipa, let candidate, awaitingHandoff == candidate.id {
                awaitingHandoff = nil
                Task { await handoff(ipa, candidate: candidate) }
            }
        }
        .sheet(item: $sharedIPA, onDismiss: {
            if let handoffURL { try? FileManager.default.removeItem(at: handoffURL) }
            handoffURL = nil
        }) { item in LiveContainerIPAActivity(url: item.url) }
        .alert("LiveContainer", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .alert("Already installed this exact build?", isPresented: $markingInstalled) {
            SwiftUI.Button("Mark as Installed") { Task { await resolve(markInstalled: true) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Confirm only after installing this exact GitHub release or workflow build in LiveContainer. A matching version label alone is insufficient.") }
        .confirmationDialog("Remove cached guest?", isPresented: $confirmingGuestRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Guest", role: .destructive) { Task { await removeUnavailableGuest() } }
        } message: {
            Text("This removes the unavailable guest’s cached metadata and GitHub update settings from SideKick. Its LiveContainer files are not changed.")
        }
    }

    @discardableResult
    @MainActor private func reload() async -> Bool {
        do {
            let state = try await environment.liveContainerStore.snapshot()
            guest = state.apps.first { $0.id == guestID }
            connection = state.connections.first { $0.id == guest?.connectionID }
            let currentConfiguration = try await GitHubUpdateConfigurationStore.shared.configuration(for: guestID)
            if configuration?.sourceIdentity != currentConfiguration?.sourceIdentity {
                candidate = nil
                hasChecked = false
                checkFailed = false
            }
            configuration = currentConfiguration
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func updateCheckIdentity(guest: LiveContainerGuest?, connection: LiveContainerConnection?) -> String? {
        guard let guest else { return nil }
        let target = guest.updateTarget
        return [target.id, target.name, target.version, target.observation ?? "",
            connection?.id.uuidString ?? "", connection?.isConnected == true ? "connected" : "disconnected",
            connection?.storageKind.rawValue ?? "", connection?.error ?? "",
            guest.isAvailable ? "available" : "unavailable", guest.warning ?? ""].joined(separator: "\n")
    }

    private func candidateMatchesCurrentGuest(_ candidate: GitHubUpdateCandidate) -> Bool {
        guard let guest, let configuration else { return false }
        return candidate == self.candidate
            && candidate.targetKind == .liveContainer
            && candidate.bundleIdentifier == guestID
            && candidate.currentVersion == guest.version
            && candidate.sourceIdentity == configuration.sourceIdentity
    }

    @MainActor private func revalidateUpdateHandoff(
        _ candidate: GitHubUpdateCandidate,
        identity: String,
        expectedConfiguration: GitHubUpdateConfiguration
    ) async -> Bool {
        guard await reload() else {
            message = "Could not verify the LiveContainer guest. Reconnect its folder and try again."
            return false
        }
        guard canCheckUpdates else {
            message = updateEligibilityMessage
            return false
        }
        guard updateCheckIdentity(guest: self.guest, connection: self.connection) == identity,
              configuration == expectedConfiguration,
              candidateMatchesCurrentGuest(candidate) else {
            message = "The guest or update source changed. Check for updates again before handing off this IPA."
            return false
        }
        return true
    }

    @MainActor private func invalidateUpdateCheck() {
        updateCheckGeneration = UUID()
        if isCheckingUpdates { updateCheckRequested = true }
    }

    @MainActor private func reloadAfterCatalogueChange() async {
        let previousIdentity = updateCheckIdentity(guest: guest, connection: connection)
        let previousConfiguration = configuration
        guard await reload() else { return }
        let guestChanged = previousIdentity != updateCheckIdentity(guest: guest, connection: connection)
        let configurationChanged = previousConfiguration != configuration
        guard guestChanged || configurationChanged else { return }
        if guestChanged {
            candidate = nil
            hasChecked = false
            checkFailed = false
        }
        invalidateUpdateCheck()
        await checkUpdates(force: true)
    }

    @MainActor private func updateCheckIsCurrent(
        generation: UUID,
        identity: String?,
        checkedConfiguration: GitHubUpdateConfiguration?,
        check: GitHubCheckResult?,
        candidates: [GitHubUpdateCandidate]
    ) async -> Bool {
        guard await reload() else { return false }
        let checkConfigurationMatches = check == nil
            || check?.checkedConfiguration == checkedConfiguration
            || (check?.state == .failed && check?.checkedConfiguration == nil)
        let candidateConfigurationMatches = candidates.first.map {
            $0.sourceIdentity == checkedConfiguration?.sourceIdentity
        } ?? true
        return generation == updateCheckGeneration
            && identity == updateCheckIdentity(guest: self.guest, connection: self.connection)
            && checkedConfiguration == configuration
            && checkConfigurationMatches
            && candidateConfigurationMatches
    }

    @MainActor private func checkUpdates(force: Bool = false) async {
        guard !working else { return }
        if isCheckingUpdates {
            if force { updateCheckRequested = true }
            return
        }
        guard canCheckUpdates else { return }

        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        var followUpsRemaining = 1
        var isFirstCheck = true
        repeat {
            if !isFirstCheck { followUpsRemaining -= 1 }
            isFirstCheck = false
            updateCheckRequested = false
            guard canCheckUpdates, let checkedGuest = self.guest else { break }

            let generation = updateCheckGeneration
            let target = checkedGuest.updateTarget
            let identity = updateCheckIdentity(guest: checkedGuest, connection: self.connection)
            let checkedConfiguration: GitHubUpdateConfiguration?
            do {
                checkedConfiguration = try await GitHubUpdateConfigurationStore.shared.configuration(for: guestID)
            } catch {
                hasChecked = true
                checkFailed = true
                checkState = .failed
                candidate = nil
                message = error.localizedDescription
                break
            }

            let result = await GitHubUpdateScanner.scanTargets([target])
            let check = result.checks.first
            if !(await updateCheckIsCurrent(generation: generation, identity: identity,
                checkedConfiguration: checkedConfiguration, check: check, candidates: result.candidates)) {
                candidate = nil
                hasChecked = true
                checkFailed = true
                checkState = .failed
                message = "The guest or update settings changed during the check. Check again for current results."
                if followUpsRemaining > 0 {
                    updateCheckRequested = true
                    continue
                }
                updateCheckRequested = false
                break
            }

            hasChecked = true
            checkFailed = result.didFail || result.checks.isEmpty
            candidate = result.candidates.first
            checkState = check?.state ?? .failed
            if message == "The guest or update settings changed during the check. Check again for current results." {
                message = nil
            }
            await environment.githubUpdateDownloads.restoreQueuedFiles(for: result.candidates, ipaImportStore: environment.ipaImportStore)
            guard await updateCheckIsCurrent(generation: generation, identity: identity,
                checkedConfiguration: checkedConfiguration, check: check, candidates: result.candidates) else {
                candidate = nil
                hasChecked = true
                checkFailed = true
                checkState = .failed
                message = "The guest or update settings changed during the check. Check again for current results."
                if followUpsRemaining > 0 {
                    updateCheckRequested = true
                    continue
                }
                updateCheckRequested = false
                break
            }
            if checkFailed {
                message = "GitHub could not check this source. Verify repository, workflow, and token settings."
            }
            await GitHubUpdateNotificationScheduler.notify(result.candidates)
        } while updateCheckRequested && followUpsRemaining > 0
        if followUpsRemaining == 0 { updateCheckRequested = false }
    }
    @MainActor private func launch() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let url = try await environment.liveContainerStore.launchURL(for: guestID)
            if !(await UIApplication.shared.open(url)) { message = "This LiveContainer URL scheme is unavailable. Check the connection scheme or open LiveContainer manually." }
        } catch { message = error.localizedDescription }
        await reload()
    }

    @MainActor private func removeUnavailableGuest() async {
        guard !working, let guest, !guest.isAvailable else { return }
        working = true
        defer { working = false }
        do {
            // Clear the source first so a failed catalogue write leaves a
            // visible guest that the user can retry removing.
            try await GitHubUpdateConfigurationStore.shared.remove(bundleIdentifier: guestID)
            try await environment.liveContainerStore.removeUnavailableGuest(guestID)
        } catch {
            message = error.localizedDescription
            return
        }
        dismiss()
    }

    @MainActor private func openContainer(_ connection: LiveContainerConnection) async {
        do {
            let url = try LiveContainerLaunch.url(scheme: connection.scheme)
            if !(await UIApplication.shared.open(url)) { message = "LiveContainer is unavailable for this scheme. Verify the installation and URL scheme." }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func updateInLiveContainer(_ candidate: GitHubUpdateCandidate) async {
        guard !working, !isCheckingUpdates else { return }
        guard await reload() else {
            message = "Could not verify the LiveContainer guest. Reconnect its folder and try again."
            return
        }
        guard canCheckUpdates else { message = updateEligibilityMessage; return }
        guard candidateMatchesCurrentGuest(candidate), let expectedConfiguration = configuration,
              let identity = updateCheckIdentity(guest: self.guest, connection: self.connection) else {
            message = "The guest or update source changed. Check for updates again before handing off this IPA."
            return
        }
        if let ipa = downloadJob?.queuedIPA { await handoff(ipa, candidate: candidate); return }
        do {
            let token = try GitHubCredentialStore().load(id: expectedConfiguration.tokenID)
            guard await revalidateUpdateHandoff(candidate, identity: identity, expectedConfiguration: expectedConfiguration) else { return }
            guard let guest = self.guest else { return }
            awaitingHandoff = candidate.id
            environment.githubUpdateDownloads.start(candidate: candidate,
                expectedBundleIdentifiers: [guest.bundleIdentifier.lowercased()],
                ipaImportStore: environment.ipaImportStore, token: token)
        } catch { message = error.localizedDescription }
    }

    @MainActor private func handoff(_ ipa: ImportedIPA, candidate: GitHubUpdateCandidate) async {
        guard !working else { return }
        working = true
        defer { working = false }
        guard await reload() else {
            message = "Could not verify the LiveContainer guest. Reconnect its folder and try again."
            return
        }
        guard canCheckUpdates else { message = updateEligibilityMessage; return }
        guard candidateMatchesCurrentGuest(candidate), let expectedConfiguration = configuration,
              ipa.githubSourceIdentity == configuration?.sourceIdentity,
              let identity = updateCheckIdentity(guest: self.guest, connection: self.connection) else {
            message = "The guest or update source changed. Check for updates again before handing off this IPA."
            return
        }
        do {
            let url = try await environment.ipaImportStore.fileURL(for: ipa)
            guard await revalidateUpdateHandoff(candidate, identity: identity, expectedConfiguration: expectedConfiguration) else { return }
            handoffURL = url
            sharedIPA = LiveContainerSharedIPA(url: url)
        } catch { message = error.localizedDescription }
    }

    @MainActor private func resolve(markInstalled: Bool) async {
        guard !working, !isCheckingUpdates, let candidate, let source = candidate.sourceIdentity else { return }
        working = true
        defer { working = false }
        do {
            let store = GitHubUpdateConfigurationStore.shared
            let applied: Bool
            if markInstalled {
                if let connection { try await environment.liveContainerStore.rescan(connection.id) }
                await reload()
                guard let guest, guest.isAvailable else { return }
                applied = try await store.recordInstalled(key: candidate.updateKey, for: guest.updateTarget, expectedSource: source)
            } else {
                applied = try await store.skip(key: candidate.updateKey, targetID: guestID, expectedSource: source)
            }
            guard applied else { message = "The update source changed. Check for updates again."; return }
            if let ipa = downloadJob?.queuedIPA { try await environment.ipaImportStore.delete(ipa) }
            environment.githubUpdateDownloads.removeJob(for: candidate)
            self.candidate = nil
            await reload()
        } catch { message = error.localizedDescription }
    }

}

private struct LiveContainerInstalledBuildDisclosure: View {
    let configuration: GitHubUpdateConfiguration
    @State private var isExpanded = false

    private var preview: String {
        guard let key = configuration.effectiveBaselineKey else { return "Choose a baseline" }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "release-v2", Int64(parts[1]) != nil {
            return "Release #\(parts[1])"
        }
        if parts.count == 6, parts[0] == "actions-v2", Int64(parts[2]) != nil {
            return "Workflow run #\(parts[2])"
        }
        return "\(configuration.source.title) · Build selected"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let key = configuration.effectiveBaselineKey {
                    detail("Full build key", value: key)
                }
                detail("Repository", value: configuration.repositoryURL)
                detail("Source", value: configuration.source.title)
                if configuration.source == .actionsArtifact {
                    detail("Workflow", value: configuration.workflowFile)
                    detail("Branch", value: configuration.branch)
                }
                if !configuration.assetName.isEmpty {
                    detail("Asset", value: configuration.assetName)
                }
                if let build = configuration.installedBuild,
                   build.key == configuration.effectiveBaselineKey,
                   build.sourceIdentity == configuration.sourceIdentity {
                    detail("Confirmed", value: build.confirmedAt.formatted())
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed GitHub build")
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LiveContainerGuestIcon: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "app.fill").resizable().scaledToFit().padding(12).foregroundStyle(.white).background(.blue.gradient) }
        }.clipShape(.rect(cornerRadius: 12))
    }
}

private struct LiveContainerSharedIPA: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LiveContainerIPAActivity: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
