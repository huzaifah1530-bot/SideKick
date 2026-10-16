import SwiftUI
import UIKit

/// A handoff of the retained IPA, with automatic GitHub source association.
/// The same saved import remains the retry record if the user leaves this page.
struct LiveContainerImportView: View {
    let app: ImportedIPA
    var opensOnArrival = false
    @Environment(AppEnvironment.self) private var environment
    @State private var catalogue = LiveContainerState()
    @State private var handoffURL: URL?
    @State private var showShare = false
    @State private var working = false
    @State private var message: String?
    @State private var confirmedGuest: LiveContainerGuest?
    @State private var selectedGuest: LiveContainerGuest?
    @State private var attemptedAutoOpen = false

    private var matches: [LiveContainerGuest] {
        catalogue.apps.filter { guest in
            guard let connection = catalogue.connections.first(where: { $0.id == guest.connectionID }) else { return false }
            return LiveContainerImportPolicy.matches(app, guest: guest, connection: connection)
        }
    }

    var body: some View {
        Form {
            Section {
                Text(app.name).font(.headline)
                Text("Version \(app.version) · Build \(app.buildVersion ?? "unknown")")
                    .foregroundStyle(.secondary)
                Text("Open the IPA in LiveContainer, or save it to Files and import it there. Return here after the import finishes.")
                SwiftUI.Button("Open IPA in LiveContainer") { Task { await share() } }
                    .disabled(working)
            }
            if let source = app.githubImportConfiguration {
                Section("GitHub Updates") {
                    Text(source.repositoryURL).textSelection(.enabled)
                    LabeledContent("Source", value: source.source.title)
                    LabeledContent("File", value: source.assetName)
                    if source.source == .actionsArtifact {
                        LabeledContent("Workflow", value: source.workflowFile)
                        LabeledContent("Branch", value: source.branch)
                    }
                    Text("SideKick keeps the repository and selected build automatically. After LiveContainer imports the IPA, return here and its update source will be attached automatically.")
                }
            }
            Section("After Importing") {
                NavigationLink("Link or Manage LiveContainer Folders") { LiveContainerConnectionsView() }
                SwiftUI.Button("Find Imported App") { Task { await rescan() } }.disabled(working)
                if working { ProgressView() }
                if let guest = confirmedGuest {
                    Label("LiveContainer app found", systemImage: "checkmark.circle.fill")
                    NavigationLink("Open App Details") { LiveContainerGuestDetailView(guestID: guest.id) }
                } else {
                    ForEach(app.githubImportConfiguration == nil || matches.count > 1 ? matches : []) { guest in
                        SwiftUI.Button {
                            selectedGuest = guest
                        } label: {
                            VStack(alignment: .leading) {
                                Text("Confirm \(guest.name)")
                                Text(catalogue.connections.first(where: { $0.id == guest.connectionID })?.name ?? guest.folder)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(working)
                    }
                    if matches.isEmpty {
                        Text("Link LiveContainer’s Applications folder and finish importing this IPA. SideKick checks again when you return. The app’s bundle ID, version and build must match.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Install in LiveContainer")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare, onDismiss: { Task { await rescan() } }) {
            if let handoffURL { LiveContainerIPAActivity(url: handoffURL) }
        }
        .confirmationDialog("Did you import this downloaded IPA into this guest?", isPresented: Binding(
            get: { selectedGuest != nil }, set: { if !$0 { selectedGuest = nil } }
        ), titleVisibility: .visible) {
            if let selectedGuest {
                SwiftUI.Button("Yes, I Imported This Build") { Task { await confirm(selectedGuest) } }
            }
        } message: {
            Text("Confirm only after LiveContainer finishes importing this file. Version labels alone cannot prove which GitHub build is installed.")
        }
        .task {
            if opensOnArrival && !attemptedAutoOpen {
                attemptedAutoOpen = true
                await share()
            } else { await rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await rescan() }
        }
        .onDisappear {
            if let handoffURL { SideKickStorageCleanup.finishTemporaryFile(handoffURL) }
            handoffURL = nil
        }
    }

    @MainActor private func share() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let url = try await environment.ipaImportStore.fileURL(for: app)
            if let handoffURL { SideKickStorageCleanup.finishTemporaryFile(handoffURL) }
            handoffURL = url
            guard var retained = try await environment.ipaImportStore.importedApps().first(where: {
                $0.id == app.id && $0.importedAt == app.importedAt
            }) else { throw IPAImportError.sourceFileMissing }
            retained.liveContainerHandoffRequested = retained.githubImportConfiguration != nil
            try await environment.ipaImportStore.saveImportedIPA(retained)
            showShare = true
        } catch {
            if let handoffURL { SideKickStorageCleanup.finishTemporaryFile(handoffURL) }
            handoffURL = nil
            message = error.localizedDescription
        }
    }

    @MainActor private func rescan() async {
        guard !working else { return }
        working = true
        confirmedGuest = nil
        defer { working = false }
        do {
            let state = try await environment.liveContainerStore.snapshot()
            var failures: [String] = []
            for connection in state.connections where connection.isConnected && connection.storageKind != .snapshot {
                do { try await environment.liveContainerStore.rescan(connection.id) }
                catch { failures.append(connection.name + ": " + error.localizedDescription) }
            }
            catalogue = try await environment.liveContainerStore.snapshot()
            message = failures.isEmpty ? nil : failures.joined(separator: "\n")
            await environment.reloadLiveContainerCatalogue()
            if app.githubImportConfiguration != nil, matches.count == 1, let guest = matches.first,
               let saved = try await GitHubUpdateConfigurationStore.shared.configuration(for: guest.id) {
                if saved.sourceIdentity == app.githubSourceIdentity {
                    confirmedGuest = guest
                    message = app.githubUpdateKey != nil && saved.installedBuild?.key == app.githubUpdateKey
                        ? "GitHub updates are configured automatically for this guest."
                        : "The GitHub source is saved. The exact installed build could not be verified automatically; review the baseline in App Details."
                } else {
                    message = "This guest already tracks a different GitHub source. Its settings were kept. Review GitHub Update Source in its app details."
                }
            }
        } catch { message = error.localizedDescription }
    }

    @MainActor private func confirm(_ selected: LiveContainerGuest) async {
        guard !working else { return }
        working = true
        selectedGuest = nil
        defer { working = false }
        do {
            try await environment.liveContainerStore.rescan(selected.connectionID)
            let fresh = try await environment.liveContainerStore.snapshot()
            guard let guest = fresh.apps.first(where: { $0.id == selected.id }),
                  let connection = fresh.connections.first(where: { $0.id == selected.connectionID }),
                  LiveContainerImportPolicy.matches(app, guest: guest, connection: connection) else {
                throw LiveContainerImportError.guestMismatch
            }
            if app.githubImportConfiguration != nil {
                guard try await GitHubUpdateConfigurationStore.shared.recordLiveContainerImport(app, guest: guest, connection: connection) else {
                    message = "This guest already tracks a different GitHub source. Its settings were kept. Review GitHub Update Source in its app details."
                    return
                }
            }
            confirmedGuest = guest
            catalogue = fresh
            message = app.githubImportConfiguration == nil ? "No GitHub source was attached to this IPA. You can configure one in App Details." : "GitHub updates are configured for this LiveContainer guest."
            await environment.reloadLiveContainerCatalogue()
        } catch { message = error.localizedDescription }
    }
}
