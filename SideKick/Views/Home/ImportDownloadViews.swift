import SwiftUI

/// The live state of an Import from URL / Install from GitHub download, shown inline on the
/// page that started it and on the page the floating downloads button reopens.
struct ImportDownloadPanel: View {
    let jobID: UUID
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

    private var store: IPAImportDownloadStore { environment.importDownloads }
    private var job: IPAImportDownloadStore.Job? { store.jobs[jobID] }

    var body: some View {
        if let job {
            switch job.state {
            case .downloading:
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Downloading").font(.body.weight(.semibold))
                        Spacer()
                        Text(percent(job.progress)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: job.progress?.fractionCompleted ?? 0).tint(.sideKickAccent)
                    if let bytes = job.progress?.bytesWritten, bytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) downloaded · keeps going if you leave")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                SwiftUI.Button("Cancel Download", role: .destructive) { Task { await store.cancel(jobID) } }

            case .needsTarget(let ipa, let installations):
                Label("\(ipa.name) is already installed", systemImage: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                ForEach(installations) { installation in
                    SwiftUI.Button {
                        Task { await store.choose(jobID, target: installation) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use as Update for \(installation.name)").foregroundStyle(Color.sideKickAccent)
                            Text("\(installation.accountEmail) · \(installation.teamIdentifier)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                SwiftUI.Button("Delete IPA", role: .destructive) { Task { await store.cancel(jobID) } }

            case .ready(let ipa, let isUpdate):
                Label(isUpdate ? "Update ready for \(ipa.name)" : "\(ipa.name) is ready to install", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                NavigationLink {
                    if isUpdate { AppManagementView(queuedUpdate: ipa) } else { AppManagementView(importedApp: ipa) }
                } label: {
                    Label(isUpdate ? "Review Update" : "Install \(ipa.name)", systemImage: "arrow.down.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.sideKickAccent)
                }
                SwiftUI.Button("Delete IPA", role: .destructive) { isConfirmingDelete = true }
                    .confirmationDialog("Delete \(ipa.name) IPA?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        SwiftUI.Button("Delete IPA", role: .destructive) { Task { await store.cancel(jobID) } }
                    } message: {
                        Text("You can download it again later.")
                    }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                SwiftUI.Button("Try Again") { store.retry(jobID) }
            }
        }
    }

    private func percent(_ progress: GitHubDownloadProgress?) -> String {
        guard let fraction = progress?.fractionCompleted else { return "Starting…" }
        return fraction > 0 && fraction < 0.01 ? "<1%" : "\(Int(fraction * 100))%"
    }
}

/// Opened from the floating downloads button.
struct ImportDownloadPage: View {
    let jobID: UUID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            if let job = environment.importDownloads.jobs[jobID] {
                Section { ImportDownloadPanel(jobID: jobID) } header: { Text(job.title) }
            } else {
                ContentUnavailableView("Download Removed", systemImage: "arrow.down.circle")
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
        .trackVisibleImportDownload(jobID)
    }
}

extension View {
    /// Hides this job from the floating button while its page is on screen.
    func trackVisibleImportDownload(_ id: UUID?) -> some View {
        modifier(VisibleImportDownload(id: id))
    }
}

private struct VisibleImportDownload: ViewModifier {
    let id: UUID?
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content
            .onAppear { if let id { environment.importDownloads.visibleJobID = id } }
            .onChange(of: id) { _, new in environment.importDownloads.visibleJobID = new }
            .onDisappear {
                if environment.importDownloads.visibleJobID == id { environment.importDownloads.visibleJobID = nil }
            }
    }
}
