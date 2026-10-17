import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Guest rows for My Apps. Navigation and alerts live on the parent List: attaching them to a
/// `Section` turns the whole section into a single row, so every guest would lift and push together.
struct LiveContainerLibrarySection: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var selectedGuestID: String?
    @Binding var sourceGuestID: String?
    @Binding var actionError: String?
    @State private var workingGuestID: String?
    private var state: LiveContainerState { environment.liveContainerState }
    private var message: String? { environment.liveContainerLoadError }

    var body: some View {
        Section {
            ForEach(state.apps) { app in
                NavigationLink {
                    LiveContainerGuestDetailView(guestID: app.id)
                } label: {
                    SideKickLibraryAppRow(
                        name: app.name,
                        versionText: app.build == app.version
                            ? app.version
                            : "\(app.version) (\(app.build))",
                        iconData: app.iconData,
                        metadata: {
                            if let connection = state.connections.first(where: { $0.id == app.connectionID }) {
                                if connection.storageKind == .snapshot || state.connections.count > 1 {
                                    Text(connection.storageKind == .snapshot ? "Snapshot · \(connection.name)" : connection.name)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if !connection.isConnected || connection.error != nil {
                                    Text("Reconnect to scan").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if !app.isAvailable { Text("Unavailable · previous metadata").font(.caption).foregroundStyle(.orange) }
                        },
                        status: {
                            if environment.githubUpdates.contains(where: { $0.bundleIdentifier == app.id && $0.isKnownNewer }) {
                                StatusBadge(title: "Update", systemImage: "arrow.down.circle.fill", tone: .accent)
                            }
                        }
                    )
                }
                .contextMenu { guestMenu(app) }
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
                Text("No apps in this folder.")
                    .foregroundStyle(.secondary)
                SwiftUI.Button {
                    Task { await rescanFolders() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(workingGuestID != nil || !state.connections.contains(where: \.isConnected))
                NavigationLink { LiveContainerConnectionsView() } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }
        } header: { Text("LiveContainer") }
    }

    @ViewBuilder
    private func guestMenu(_ app: LiveContainerGuest) -> some View {
        let hasUpdate = environment.githubUpdates.contains { $0.bundleIdentifier == app.id }
        let hasSource = environment.githubConfigurations.contains { $0.id == app.id }
        Section {
            SwiftUI.Button {
                Task { await launch(app) }
            } label: {
                Label("Open in LiveContainer", systemImage: "play.circle")
            }
            .disabled(workingGuestID != nil || !canLaunch(app))
            if hasUpdate {
                SwiftUI.Button {
                    selectedGuestID = app.id
                } label: {
                    Label("Review Update", systemImage: "arrow.down.circle")
                }
            }
        }
        Section {
            if hasSource {
                SwiftUI.Button {
                    environment.requestGitHubUpdateCheck(force: true)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(environment.isCheckingGitHubUpdates)
            }
            SwiftUI.Button { sourceGuestID = app.id } label: {
                Label(hasSource ? "Update Source…" : "Track GitHub Updates…", systemImage: "arrow.down.app")
            }
        }
        Section {
            SwiftUI.Button {
                Task { await refresh(app) }
            } label: {
                Label("Rescan Folder", systemImage: "arrow.clockwise")
            }
            .disabled(workingGuestID != nil || connection(for: app)?.isConnected != true)
            SwiftUI.Button {
                UIPasteboard.general.string = app.bundleIdentifier
            } label: {
                Label("Copy Bundle ID", systemImage: "doc.on.doc")
            }
        }
    }

    private func connection(for app: LiveContainerGuest) -> LiveContainerConnection? {
        state.connections.first(where: { $0.id == app.connectionID })
    }

    @MainActor private func rescanFolders() async {
        guard workingGuestID == nil else { return }
        workingGuestID = "catalogue-rescan"
        defer { workingGuestID = nil }
        var failures: [String] = []
        for connection in state.connections where connection.isConnected {
            do {
                try await environment.liveContainerStore.rescan(connection.id)
            } catch {
                failures.append("\(connection.name): \(error.localizedDescription)")
            }
        }
        await environment.reloadLiveContainerCatalogue()
        if !failures.isEmpty { actionError = failures.joined(separator: "\n") }
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
    @State private var replacingConnection: LiveContainerConnection?

    var body: some View {
        List {
            if isWorking { Section { ProgressView("Reading folder…") } }

            if state.connections.isEmpty {
                ContentUnavailableView {
                    Label("No LiveContainer Folder", systemImage: "folder")
                } description: {
                    Text("Choose the Applications folder LiveContainer shows in Files. SideKick only reads it.")
                } actions: {
                    SwiftUI.Button { addConnection() } label: {
                        Text("Choose Folder").font(.headline).padding(.horizontal, Spacing.m)
                    }
                    .primaryActionStyle()
                    .disabled(isWorking)
                }
                .listRowBackground(Color.clear)
            }

            ForEach(state.connections) { connection in
                Section {
                    connectionRow(connection)
                        .contextMenu { connectionMenu(connection) }
                        .swipeActions(edge: .trailing) {
                            SwiftUI.Button(role: .destructive) { forgetting = connection } label: {
                                Label("Forget", systemImage: "trash")
                            }
                            .disabled(isWorking)
                        }
                        .swipeActions(edge: .leading) {
                            SwiftUI.Button { Task { await run { try await environment.liveContainerStore.rescan(connection.id) } } } label: {
                                Label("Rescan", systemImage: "arrow.clockwise")
                            }
                            .tint(.sideKickAccent)
                            .disabled(isWorking || !connection.isConnected)
                        }
                    if let error = connection.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    ForEach(Array(connection.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.footnote).foregroundStyle(.secondary)
                    }
                    if state.pendingForgetGuestIDs[connection.id] != nil {
                        Label("Forget didn’t finish. Retry to remove remaining sources and downloads.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if !connection.isConnected || connection.error != nil {
                        SwiftUI.Button { changeFolder(connection) } label: {
                            Label("Reconnect Folder", systemImage: "folder")
                        }
                        .disabled(isWorking)
                    }
                }
            }

            Section {
                DisclosureGroup("New Folder Options") {
                    TextField("Connection name", text: $name)
                    Picker("Storage type", selection: $kind) {
                        ForEach(LiveContainerStorageKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Launch scheme", text: $scheme).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("Change these only if your LiveContainer setup needs it. Snapshots can’t launch apps or confirm versions. Guest files are never changed.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button { addConnection() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add LiveContainer Folder")
                    .disabled(isWorking)
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
        .alert("Forget this folder?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            SwiftUI.Button("Forget", role: .destructive) {
                guard let connection = forgetting else { return }
                forgetting = nil
                Task { await run {
                    let guestPrefix = "livecontainer:\(connection.id.uuidString):"
                    let configurations = try await GitHubUpdateConfigurationStore.shared.all()
                    let imports = try await environment.ipaImportStore.importedApps()
                    let configuredGuestIDs = configurations.map(\.bundleIdentifier)
                        .filter { $0.hasPrefix(guestPrefix) }
                    let queuedGuestIDs = imports.compactMap(\.queuedForInstalledAppID)
                        .filter { $0.hasPrefix(guestPrefix) }
                    let ids = try await environment.liveContainerStore.beginForget(
                        connection.id,
                        additionalGuestIDs: configuredGuestIDs + queuedGuestIDs
                    )
                    for id in ids {
                        try await environment.githubUpdateDownloads.prepareForgettingGuest(
                            targetID: id,
                            ipaImportStore: environment.ipaImportStore
                        )
                        try await GitHubUpdateConfigurationStore.shared.remove(bundleIdentifier: id)
                        try await environment.liveContainerStore.completeForgetSource(id, connectionID: connection.id)
                    }
                } }
            }
            SwiftUI.Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("SideKick removes its cached apps, GitHub sources and downloaded updates for this folder. LiveContainer’s files stay in place.")
        }
        .confirmationDialog("Choose a folder for \(replacingConnection?.name ?? "this connection")?", isPresented: Binding(get: { replacingConnection != nil }, set: { if !$0 { replacingConnection = nil } }), titleVisibility: .visible) {
            SwiftUI.Button("Choose Folder") {
                guard let connection = replacingConnection else { return }
                replacingConnection = nil
                changeFolder(connection)
            }
            SwiftUI.Button("Cancel", role: .cancel) { replacingConnection = nil }
        } message: {
            Text("Apps and GitHub sources stay linked to this connection. LiveContainer files aren’t changed.")
        }
    }

    @MainActor private func reload() async {
        do { state = try await environment.liveContainerStore.snapshot() } catch { self.error = error.localizedDescription }
    }

    private func addConnection() {
        reconnectID = nil
        if !state.connections.isEmpty { name = "LiveContainer \(state.connections.count + 1)" }
        picker = true
    }

    private func changeFolder(_ connection: LiveContainerConnection) {
        reconnectID = connection.id
        name = connection.name
        scheme = connection.scheme
        kind = connection.storageKind
        picker = true
    }

    private func connectionRow(_ connection: LiveContainerConnection) -> some View {
        let healthy = connection.isConnected && connection.error == nil
        let guests = state.apps.filter { $0.connectionID == connection.id }.count
        return HStack(spacing: Spacing.s) {
            Image(systemName: connection.storageKind == .snapshot ? "archivebox" : "folder.fill")
                .font(.title3)
                .foregroundStyle(healthy ? Color.sideKickAccent : Color.orange)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.body.weight(.semibold))
                Text(connectionSubtitle(connection, guests: guests))
                    .font(.subheadline)
                    .foregroundStyle(healthy ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu { connectionMenu(connection) } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Manage \(connection.name)")
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func connectionSubtitle(_ connection: LiveContainerConnection, guests: Int) -> String {
        guard connection.isConnected else { return "Disconnected · reconnect to scan" }
        if connection.error != nil { return "Needs attention" }
        let apps = guests == 1 ? "1 app" : "\(guests) apps"
        if let date = connection.lastSuccessfulScan {
            return "\(apps) · scanned \(date.formatted(.relative(presentation: .named)))"
        }
        return apps
    }

    @ViewBuilder
    private func connectionMenu(_ connection: LiveContainerConnection) -> some View {
        let forgetPending = state.pendingForgetGuestIDs[connection.id] != nil
        Section {
            SwiftUI.Button { Task { await run { try await environment.liveContainerStore.rescan(connection.id) } } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isWorking || !connection.isConnected || forgetPending)
            SwiftUI.Button { replacingConnection = connection } label: {
                Label(connection.isConnected ? "Change Folder…" : "Reconnect Folder…", systemImage: "folder")
            }
            .disabled(isWorking || forgetPending)
        }
        Section {
            if connection.isConnected {
                SwiftUI.Button { Task { await run { try await environment.liveContainerStore.disconnect(connection.id) } } } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .disabled(isWorking)
            }
            SwiftUI.Button(role: .destructive) { forgetting = connection } label: {
                Label(forgetPending ? "Retry Forget" : "Forget Folder…", systemImage: "trash")
            }
            .disabled(isWorking)
        }
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
    @State private var isBeingForgotten = false
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

    private var canConfirmInstalledBuild: Bool {
        checkState == .unknownInstalledBuild || downloadJob?.queuedIPA != nil
    }

    private var canCheckUpdates: Bool {
        guard let guest = self.guest else { return false }
        return !isBeingForgotten && connection?.isConnected == true && connection?.error == nil
            && connection?.storageKind != .snapshot && guest.isAvailable && guest.warning == nil
    }

    private var updateEligibilityMessage: String {
        if isBeingForgotten { return "This guest is being forgotten. Retry Forget in Connection & Rescan if cleanup needs attention." }
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
                    DetailHeader(
                        iconData: guest.iconData,
                        title: guest.name,
                        subtitle: guest.build == guest.version ? guest.version : "\(guest.version) (\(guest.build))"
                    ) {
                        guestBadge(guest)
                    }
                    HStack(spacing: Spacing.s) {
                        SwiftUI.Button { Task { await launch() } } label: {
                            ActionLabel("Open", isWorking: working && !isCheckingUpdates)
                        }
                        .primaryActionStyle()
                        .disabled(working || !canLaunch(guest))

                        if configuration != nil {
                            SwiftUI.Button { Task { await checkUpdates() } } label: {
                                ActionLabel("Check", systemImage: "arrow.clockwise", isWorking: isCheckingUpdates)
                            }
                            .secondaryActionStyle()
                            .tint(.sideKickAccent)
                            .disabled(working || isCheckingUpdates || !canCheckUpdates)
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
                .listRowSeparator(.hidden)

                if let warning = guest.warning ?? connection?.error {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        NavigationLink { LiveContainerConnectionsView() } label: {
                            Text("Reconnect Folder")
                        }
                    }
                }

                if let candidate {
                    updateReviewSection(for: guest, candidate: candidate)
                }

                Section {
                    NavigationLink { GitHubUpdateSettingsView(target: guest.updateTarget) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("GitHub Updates", systemImage: "arrow.down.app")
                            if configuration != nil {
                                Text(hasChecked ? checkState.message : "Tap Check to look for newer builds.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .disabled(isBeingForgotten)
                    if let configuration {
                        LiveContainerInstalledBuildDisclosure(configuration: configuration)
                            .id(configuration.sourceIdentity + "\n" + (configuration.effectiveBaselineKey ?? ""))
                    }
                } footer: {
                    if isBeingForgotten {
                        Text(updateEligibilityMessage)
                    } else if configuration?.source == .actionsArtifact {
                        Text("Actions builds need a GitHub token with Actions read access.")
                    } else if configuration == nil {
                        Text("Track a GitHub repository for new builds of this app.")
                    }
                }

                Section {
                    DisclosureGroup("Details") {
                        LabeledContent("Bundle ID", value: guest.bundleIdentifier).textSelection(.enabled)
                        LabeledContent("App folder", value: guest.folder).textSelection(.enabled)
                        LabeledContent("Folder", value: connection?.name ?? "Missing")
                        if let connection { LabeledContent("Storage", value: connection.storageKind.title) }
                        LabeledContent("Last seen", value: guest.lastSeen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } else { ContentUnavailableView("App Not Found", systemImage: "app.dashed") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(guest?.name ?? "LiveContainer App")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let guest {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            if let connection {
                                SwiftUI.Button { Task { await openContainer(connection) } } label: {
                                    Label("Open LiveContainer", systemImage: "square.stack.3d.up")
                                }
                            }
                            if let candidate, let url = URL(string: candidate.repositoryURL ?? "") {
                                Link(destination: url) { Label("View on GitHub", systemImage: "safari") }
                            }
                        }
                        Section {
                            NavigationLink { LiveContainerConnectionsView() } label: {
                                Label("Manage Folder", systemImage: "folder")
                            }
                            SwiftUI.Button { UIPasteboard.general.string = guest.bundleIdentifier } label: {
                                Label("Copy Bundle ID", systemImage: "doc.on.doc")
                            }
                        }
                        if !guest.isAvailable {
                            Section {
                                SwiftUI.Button(role: .destructive) { confirmingGuestRemoval = true } label: {
                                    Label("Remove from SideKick…", systemImage: "trash")
                                }
                                .disabled(working || isCheckingUpdates)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
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
        .alert("Installed this exact build in LiveContainer?", isPresented: $markingInstalled) {
            SwiftUI.Button("Mark as Installed") { Task { await resolve(markInstalled: true) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Confirm only after installing this exact GitHub release or workflow build in LiveContainer. A matching version label alone is insufficient.") }
        .confirmationDialog("Remove cached guest?", isPresented: $confirmingGuestRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Guest", role: .destructive) { Task { await removeUnavailableGuest() } }
        } message: {
            Text("This removes the unavailable guest’s cached metadata and GitHub update settings from SideKick. Its LiveContainer files are not changed.")
        }
    }

    private func canLaunch(_ guest: LiveContainerGuest) -> Bool {
        connection?.isConnected == true && connection?.storageKind != .snapshot && guest.isAvailable && guest.warning == nil
    }

    @ViewBuilder
    private func guestBadge(_ guest: LiveContainerGuest) -> some View {
        if !guest.isAvailable {
            StatusBadge(title: "Unavailable", systemImage: "exclamationmark.triangle.fill", tone: .warning)
        } else if let candidate, candidate.isKnownNewer {
            StatusBadge(title: "Update available", systemImage: "arrow.down.circle.fill", tone: .accent)
        } else if connection?.isConnected != true || connection?.error != nil {
            StatusBadge(title: "Folder disconnected", systemImage: "folder.badge.questionmark", tone: .warning)
        } else {
            StatusBadge(title: "In LiveContainer", systemImage: "square.stack.3d.up.fill", tone: .neutral)
        }
    }

    private func updateReviewSection(for guest: LiveContainerGuest, candidate: GitHubUpdateCandidate) -> some View {
        Section {
            LabeledContent("Installed", value: "\(guest.version) (\(guest.build))")
            LabeledContent("Available", value: candidate.newVersion)
            Text(candidate.title).font(.subheadline).foregroundStyle(.secondary)
            GitHubUpdateDownloadControls(
                job: downloadJob,
                onDownload: { Task { await updateInLiveContainer(candidate, handoffIfQueued: false) } },
                onCancel: { environment.githubUpdateDownloads.cancelDownload(for: candidate) },
                onSkip: { Task { await resolve(markInstalled: false) } },
                isDisabled: working || isCheckingUpdates || !canCheckUpdates,
                isSkipDisabled: working || isCheckingUpdates
            ) {
                SwiftUI.Button { Task { await updateInLiveContainer(candidate) } } label: {
                    ActionLabel("Send to LiveContainer", systemImage: "square.and.arrow.up")
                }
                .primaryActionStyle()
            }
            if canConfirmInstalledBuild {
                SwiftUI.Button { markingInstalled = true } label: {
                    Label("I’ve Installed This Build", systemImage: "checkmark.circle")
                }
                .disabled(working || isCheckingUpdates)
            }
            if !canCheckUpdates {
                Label(updateEligibilityMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(candidate.isKnownNewer ? "Update" : "Build to Review")
        } footer: {
            Text("Download, send to LiveContainer, then confirm once it’s installed.")
        }
    }

    @discardableResult
    @MainActor private func reload() async -> Bool {
        do {
            let state = try await environment.liveContainerStore.snapshot()
            isBeingForgotten = state.pendingForgetGuestIDs.values.contains { $0.contains(guestID) }
            if isBeingForgotten {
                candidate = nil
                awaitingHandoff = nil
            }
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
            guest.isAvailable ? "available" : "unavailable", guest.warning ?? "",
            isBeingForgotten ? "forgetting" : "retained"].joined(separator: "\n")
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
            guard let check,
                  await environment.publishDetailGitHubCheck(check, target: target) else {
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
    @MainActor private func updateInLiveContainer(_ candidate: GitHubUpdateCandidate, handoffIfQueued: Bool = true) async {
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
        if handoffIfQueued, let ipa = downloadJob?.queuedIPA { await handoff(ipa, candidate: candidate); return }
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
        guard !markInstalled || canConfirmInstalledBuild else {
            message = "Download and install this build in LiveContainer before confirming it, or set the installed build in Update Source & Installed Build."
            return
        }
        guard canCheckUpdates else { message = updateEligibilityMessage; return }
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
                applied = try await store.skip(
                    key: candidate.updateKey,
                    title: candidate.title,
                    date: candidate.buildDate,
                    targetID: guestID,
                    expectedSource: source
                )
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

private struct LiveContainerSharedIPA: Identifiable {
    let id = UUID()
    let url: URL
}

struct LiveContainerIPAActivity: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
