import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LiveContainerLibrarySection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = LiveContainerState()
    @State private var message: String?

    var body: some View {
        Group {
            if !state.apps.isEmpty {
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
                .fullWidthListSeparators()
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("LiveContainer") }
            }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerDidChange)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerCheckRequested)) { _ in
            Task { await reload() }
        }
    }

    @MainActor private func reload() async {
        do { state = try await environment.liveContainerStore.snapshot() }
        catch { message = error.localizedDescription }
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
    @State private var guest: LiveContainerGuest?
    @State private var connection: LiveContainerConnection?
    @State private var hasChecked = false
    @State private var checkFailed = false
    @State private var candidate: GitHubUpdateCandidate?
    @State private var configuration: GitHubUpdateConfiguration?
    @State private var working = false
    @State private var message: String?
    @State private var markingInstalled = false
    @State private var checkState: GitHubCheckState = .notConfigured
    @State private var awaitingHandoff: String?
    @State private var sharedIPA: LiveContainerSharedIPA?
    @State private var handoffURL: URL?

    private var downloadJob: GitHubUpdateDownloadJob? {
        candidate.flatMap { environment.githubUpdateDownloads.jobs[$0.id] }
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
                        .disabled(working || connection?.isConnected != true || connection?.storageKind == .snapshot || !guest.isAvailable)
                    if let connection {
                        SwiftUI.Button { Task { await openContainer(connection) } } label: { Label("Open LiveContainer", systemImage: "square.stack.3d.up") }
                    }
                } footer: { Text("SideKick requests a launch. LiveContainer handles authentication, JIT, and errors; accepting a URL does not confirm that the guest started.") }
                Section("GitHub Updates") {
                    NavigationLink { GitHubUpdateSettingsView(target: guest.updateTarget) } label: {
                        Label("Update Source & Installed Build", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    SwiftUI.Button { Task { await checkUpdates() } } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                        .disabled(working || connection?.isConnected != true || connection?.storageKind == .snapshot)
                    if let configuration {
                        LabeledContent("Installed GitHub build", value: configuration.effectiveBaselineKey ?? "Choose a baseline").textSelection(.enabled)
                    }
                    if let candidate {
                        SwiftUI.Button { Task { await updateInLiveContainer(candidate) } } label: {
                            Label(downloadJob?.isDownloading == true ? "Downloading IPA…" : "Update in LiveContainer", systemImage: "arrow.down.app")
                        }
                        .disabled(working || downloadJob?.isDownloading == true)
                        if let progress = downloadJob?.progress, downloadJob?.isDownloading == true { ProgressView(value: progress) }
                        if let error = downloadJob?.errorMessage { Text(error).foregroundStyle(.orange) }
                        LabeledContent("Available", value: candidate.newVersion)
                        if let url = URL(string: candidate.repositoryURL ?? "https://github.com") {
                            Link(destination: url) { Label("View on GitHub", systemImage: "arrow.up.right.square") }
                        }
                        SwiftUI.Button { markingInstalled = true } label: { Label("Already Installed This Build", systemImage: "checkmark.circle") }
                        SwiftUI.Button { Task { await resolve(markInstalled: false) } } label: { Label("Skip This Build", systemImage: "forward.end") }
                        Text("Update downloads the IPA, then opens the share sheet. Choose LiveContainer to start installing it. Confirm this build after installation finishes.").font(.footnote).foregroundStyle(.secondary)
                    } else if configuration != nil { Text(hasChecked ? checkState.message : "Check this source for newer builds.").foregroundStyle(.secondary) }
                    if working { ProgressView() }
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
                }
            } else { ContentUnavailableView("Guest Not Found", systemImage: "app.dashed") }
        }
        .navigationTitle(guest?.name ?? "LiveContainer Guest")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload(); await checkUpdates() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerDidChange)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in Task { await reload(); await checkUpdates() } }
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
    }

    @MainActor private func reload() async {
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
        } catch { message = error.localizedDescription }
    }
    @MainActor private func checkUpdates() async {
        guard !working, let guest, connection?.isConnected == true, connection?.error == nil,
              connection?.storageKind != .snapshot, guest.isAvailable, guest.warning == nil else { return }
        working = true
        defer { working = false }
        let result = await GitHubUpdateScanner.scanTargets([guest.updateTarget])
        guard let current = try? await GitHubUpdateConfigurationStore.shared.configuration(for: guestID),
              result.candidates.first?.sourceIdentity == nil || result.candidates.first?.sourceIdentity == current.sourceIdentity else { return }
        hasChecked = true
        checkFailed = result.didFail
        candidate = result.candidates.first
        checkState = result.checks.first?.state ?? .failed
        await environment.githubUpdateDownloads.restoreQueuedFiles(for: result.candidates, ipaImportStore: environment.ipaImportStore)
        if result.didFail { message = "GitHub could not check this source. Verify repository, workflow, and token settings." }
        await GitHubUpdateNotificationScheduler.notify(result.candidates)
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
    @MainActor private func openContainer(_ connection: LiveContainerConnection) async {
        do {
            let url = try LiveContainerLaunch.url(scheme: connection.scheme)
            if !(await UIApplication.shared.open(url)) { message = "LiveContainer is unavailable for this scheme. Verify the installation and URL scheme." }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func updateInLiveContainer(_ candidate: GitHubUpdateCandidate) async {
        guard !working else { return }
        if let ipa = downloadJob?.queuedIPA { await handoff(ipa, candidate: candidate); return }
        do {
            guard let configuration = try await GitHubUpdateConfigurationStore.shared.configuration(for: guestID),
                  configuration.sourceIdentity == candidate.sourceIdentity, let guest else { return }
            let token = try GitHubCredentialStore().load(id: configuration.tokenID)
            awaitingHandoff = candidate.id
            environment.githubUpdateDownloads.start(candidate: candidate,
                expectedBundleIdentifiers: [guest.bundleIdentifier.lowercased()],
                ipaImportStore: environment.ipaImportStore, token: token)
        } catch { message = error.localizedDescription }
    }

    @MainActor private func handoff(_ ipa: ImportedIPA, candidate: GitHubUpdateCandidate) async {
        working = true
        defer { working = false }
        do {
            guard let current = try await GitHubUpdateConfigurationStore.shared.configuration(for: guestID),
                  current.sourceIdentity == candidate.sourceIdentity,
                  ipa.githubSourceIdentity == current.sourceIdentity else {
                message = "The update source changed. Check for updates again."
                return
            }
            let url = try await environment.ipaImportStore.fileURL(for: ipa)
            handoffURL = url
            sharedIPA = LiveContainerSharedIPA(url: url)
        } catch { message = error.localizedDescription }
    }

    @MainActor private func resolve(markInstalled: Bool) async {
        guard let candidate, let source = candidate.sourceIdentity else { return }
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
