import SwiftUI

/// Saved when an update IPA is handed to LiveContainer. SideKick can't see inside LiveContainer,
/// so on the next return (including after a restart) it asks whether the install worked and
/// records the build only when the user confirms.
struct LiveContainerHandoffRecord: Codable, Equatable, Identifiable {
    var id: String { guestID + "|" + updateKey }
    let guestID: String
    let appName: String
    let iconData: Data?
    let installedVersion: String
    let newVersion: String
    let title: String
    let updateKey: String
    let sourceIdentity: String
    let sharedAt: Date

    private static let key = "sidekick.livecontainer.pending-handoff"

    static func pending() -> LiveContainerHandoffRecord? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(LiveContainerHandoffRecord.self, from: data) else { return nil }
        // An unanswered question older than a week is stale.
        guard record.sharedAt > .now.addingTimeInterval(-7 * 86_400) else { clear(); return nil }
        return record
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    init(guest: LiveContainerGuest, candidate: GitHubUpdateCandidate, source: String) {
        guestID = guest.id
        appName = guest.name
        iconData = guest.iconData
        installedVersion = guest.build == guest.version ? guest.version : "\(guest.version) (\(guest.build))"
        newVersion = candidate.newVersion
        title = candidate.title
        updateKey = candidate.updateKey
        sourceIdentity = source
        sharedAt = .now
    }
}

struct LiveContainerHandoffSheet: View {
    let record: LiveContainerHandoffRecord
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorMessage: String?
    @State private var didRecord = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    VStack(spacing: Spacing.s) {
                        SideKickAppIcon(data: record.iconData, size: .hero)
                        Text(didRecord ? "Update Recorded" : "Did the Update Install?")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(record.appName).font(.headline).foregroundStyle(.secondary)
                        HStack(spacing: Spacing.xs) {
                            Text(record.installedVersion).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(Color.sideKickAccent).accessibilityLabel("to")
                            Text(record.newVersion).fontWeight(.semibold)
                        }
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }
                    Text(didRecord
                         ? "SideKick will check for updates newer than this build."
                         : "You sent this build to LiveContainer. Confirm once LiveContainer has replaced the app so SideKick tracks the right version.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: SideKickLayout.readableWidth)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(Color.sideKickCanvas)
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    if didRecord {
                        SwiftUI.Button { dismiss() } label: { ActionLabel("Done") }.primaryActionStyle()
                    } else {
                        SwiftUI.Button { Task { await confirm() } } label: {
                            ActionLabel("Yes, It’s Installed", isWorking: working)
                        }
                        .primaryActionStyle()
                        .disabled(working)
                        HStack(spacing: Spacing.l) {
                            SwiftUI.Button("Not Yet") { dismiss() }
                            SwiftUI.Button("It Didn’t Install", role: .destructive) {
                                LiveContainerHandoffRecord.clear()
                                dismiss()
                            }
                        }
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(working)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SwiftUI.Button("Later") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        // Fully expanded: at half height the answer buttons covered the explanation.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @MainActor private func confirm() async {
        working = true
        defer { working = false }
        errorMessage = nil
        do {
            let snapshot = try await environment.liveContainerStore.snapshot()
            if let guest = snapshot.apps.first(where: { $0.id == record.guestID }) {
                try? await environment.liveContainerStore.rescan(guest.connectionID)
            }
            let fresh = try await environment.liveContainerStore.snapshot()
            guard let guest = fresh.apps.first(where: { $0.id == record.guestID }), guest.isAvailable else {
                errorMessage = "SideKick can’t see this app in LiveContainer. Reconnect the folder, then try again."
                return
            }
            let applied = try await GitHubUpdateConfigurationStore.shared.recordInstalled(
                key: record.updateKey, for: guest.updateTarget, expectedSource: record.sourceIdentity)
            guard applied else {
                errorMessage = "The update source changed since you sent this build. Check for updates again."
                LiveContainerHandoffRecord.clear()
                return
            }
            // The downloaded IPA is no longer needed.
            let downloads = environment.githubUpdateDownloads
            if let candidate = downloads.candidates.values.first(where: {
                $0.bundleIdentifier == record.guestID && $0.updateKey == record.updateKey
            }) {
                try? await downloads.discardDownload(for: candidate, ipaImportStore: environment.ipaImportStore)
            }
            if let leftovers = try? await environment.ipaImportStore.importedApps() {
                for ipa in leftovers where ipa.queuedForInstalledAppID == record.guestID && ipa.githubUpdateKey == record.updateKey {
                    try? await environment.ipaImportStore.delete(ipa)
                }
            }
            LiveContainerHandoffRecord.clear()
            NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
            didRecord = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
