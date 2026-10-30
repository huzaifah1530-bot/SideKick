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

            case .needsTarget(let ipa, _):
                Label("Imported \(ipa.name)", systemImage: "arrow.down.doc")
                    .font(.body.weight(.semibold))
                SwiftUI.Button("Review Imported Package") { store.reviewRequestedJobID = jobID }

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
    /// Tracks the visible download and opens matching-package review at page level.
    func trackVisibleImportDownload(_ id: UUID?) -> some View {
        modifier(VisibleImportDownload(id: id))
    }
}

private struct VisibleImportDownload: ViewModifier {
    let id: UUID?
    @Environment(AppEnvironment.self) private var environment
    @State private var showingImportReview = false
    @State private var autoReviewedPackage: ImportedIPA?
    @State private var isVisible = false

    private var store: IPAImportDownloadStore { environment.importDownloads }
    private var job: IPAImportDownloadStore.Job? { id.flatMap { store.jobs[$0] } }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                if let id { store.visibleJobID = id }
                openImportReviewIfNeeded()
            }
            .onChange(of: id) { _, new in
                store.visibleJobID = new
                openImportReviewIfNeeded()
            }
            .onChange(of: job?.state) { _, _ in openImportReviewIfNeeded() }
            .onChange(of: store.reviewRequestedJobID) { _, requested in
                if let requested, requested == id, isVisible {
                    store.reviewRequestedJobID = nil
                    showingImportReview = true
                }
            }
            .onDisappear {
                isVisible = false
                if !showingImportReview, store.visibleJobID == id { store.visibleJobID = nil }
            }
            .navigationDestination(isPresented: $showingImportReview) {
                if let id, case .needsTarget(let ipa, let installations) = job?.state {
                    MatchingIPAImportReviewView(app: ipa, installations: installations,
                        onQueueUpdate: { identifier in
                            if let target = installations.first(where: { $0.id == identifier }) {
                                await store.choose(id, target: target)
                            }
                            showingImportReview = false
                        },
                        onSeparateInstall: {
                            await store.choose(id, target: nil)
                            showingImportReview = false
                        },
                        onCancel: {
                            showingImportReview = false
                            Task { await store.cancel(id) }
                        })
                    .id(ipa.importedAt)
                }
            }
    }

    private func openImportReviewIfNeeded() {
        guard isVisible, let id else { return }
        if case .needsTarget(let ipa, _) = job?.state, autoReviewedPackage != ipa {
            autoReviewedPackage = ipa
            store.reviewRequestedJobID = nil
            showingImportReview = true
        } else if store.reviewRequestedJobID == id {
            store.reviewRequestedJobID = nil
            showingImportReview = true
        }
    }
}
