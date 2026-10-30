import SwiftUI

/// Prepared packages stay outside the library until one of these choices is saved.
struct MatchingIPAImportReviewView: View {
    let app: ImportedIPA
    let installations: [InstalledAppSummary]
    let onQueueUpdate: (String) async -> Void
    let onSeparateInstall: () async -> Void
    let onCancel: () -> Void
    @State private var selectedTargetID: String?
    private enum Action: Equatable { case update, separate }
    @State private var workingAction: Action?
    private var isWorking: Bool { workingAction != nil }
    @State private var didFinish = false

    init(app: ImportedIPA, installations: [InstalledAppSummary],
         onQueueUpdate: @escaping (String) async -> Void,
         onSeparateInstall: @escaping () async -> Void, onCancel: @escaping () -> Void) {
        self.app = app
        self.installations = installations
        self.onQueueUpdate = onQueueUpdate
        self.onSeparateInstall = onSeparateInstall
        self.onCancel = onCancel
        _selectedTargetID = State(initialValue: installations.count == 1 ? installations.first?.id : nil)
    }

    var body: some View {
        List {
            Section {
                DetailHeader(iconData: app.iconData, title: app.name, subtitle: app.version)
                StatusBadge(title: "Imported", systemImage: "arrow.down.doc", tone: .neutral)
            }
            .listRowBackground(Color.clear)
            Section("Package") {
                LabeledContent("Bundle ID", value: app.bundleIdentifier)
                    .textSelection(.enabled)
                LabeledContent("Version", value: app.version)
                if let build = app.buildVersion { LabeledContent("Build", value: build) }
            }
            Section {
                if installations.count > 1 {
                    Picker("Queue Update For", selection: $selectedTargetID) {
                        Text("Choose an installed copy").tag(String?.none)
                        ForEach(installations) { installation in
                            installationLabel(installation).tag(Optional(installation.id))
                        }
                    }
                    .pickerStyle(.inline)
                } else if let installation = installations.first {
                    installationLabel(installation)
                }
            } header: {
                Text(installations.count == 1 ? (installations.first?.isActive == false ? "Saved Copy" : "Installed Copy") : "Installed Copies")
            } footer: {
                Text("Queue this package for an installed app, or keep it in Imports to choose how to sign it later.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Imported Package")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                SwiftUI.Button {
                    guard let selectedTargetID, !isWorking else { return }
                    workingAction = .update
                    didFinish = true
                    Task { await onQueueUpdate(selectedTargetID) }
                } label: { ActionLabel("Queue for Update", isWorking: workingAction == .update) }
                .primaryActionStyle()
                .disabled(isWorking || selectedTargetID == nil)
                SwiftUI.Button {
                    guard !isWorking else { return }
                    workingAction = .separate
                    didFinish = true
                    Task { await onSeparateInstall() }
                } label: { ActionLabel("Install as a Separate App", systemImage: "square.on.square", isWorking: workingAction == .separate) }
                .secondaryActionStyle()
                .disabled(isWorking)
                SwiftUI.Button("Cancel", role: .cancel) {
                    didFinish = true
                    onCancel()
                }
                .frame(minHeight: 44)
                .disabled(isWorking)
            }
        }
        .onDisappear { if !didFinish { onCancel() } }
    }

    private func installationLabel(_ installation: InstalledAppSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(installation.name).font(.body.weight(.semibold))
            Text("\(installation.version) · \(installation.accountEmail)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(installation.id).font(.footnote).foregroundStyle(.secondary)
            if !installation.isActive { Text("Offloaded").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
