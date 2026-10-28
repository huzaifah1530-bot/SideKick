import SwiftUI

struct StorageFilesView: View {
    @State private var items: [RemovableStorageItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Delete files individually, or browse All App Data in Storage to manage other files and folders. Only current app builds, backups and settings ask for confirmation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Measuring files…") }
            else if items.isEmpty { ContentUnavailableView("No Removable Files", systemImage: "folder") }
            ForEach(items) { item in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    StorageRemovalAction(item: item)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Cached & Temporary Files")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickStorageDidChange)) { _ in Task { await reload() } }
    }

    @MainActor private func reload() async {
        loading = true
        defer { loading = false }
        do { items = try await SideKickStorageCleanup.items(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct StorageRemovalAction: View {
    let item: RemovableStorageItem
    var body: some View { ManagedStorageRemovalAction(url: item.url) }
}

struct ManagedStorageRemovalAction: View {
    let url: URL
    @Environment(AppEnvironment.self) private var environment
    @State private var review: ManagedStorageReview?
    @State private var confirming = false
    @State private var working = false
    @State private var queued = false
    @State private var error: String?

    var body: some View {
        Group {
            if queued {
                Text("Scheduled for deletion on next launch").font(.footnote).foregroundStyle(.secondary)
            } else {
                SwiftUI.Button(role: .destructive) {
                    guard let review else { return }
                    if review.warning != nil { confirming = true }
                    else { Task { await remove(confirmed: false) } }
                } label: {
                    Label(review?.requiresRestart == true ? "Delete on Next Launch" : "Delete", systemImage: "trash")
                }
                .disabled(working || review == nil)
            }
        }
        .task { await reloadReview() }
        .alert("Delete important files?", isPresented: $confirming) {
            SwiftUI.Button(review?.requiresRestart == true ? "Delete on Next Launch" : "Delete", role: .destructive) {
                Task { await remove(confirmed: true) }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text(review?.warning ?? "") }
        .alert("Storage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reloadReview() async {
        do { review = try await ManagedStorageFiles.review(url) }
        catch { self.error = error.localizedDescription }
    }

    private func remove(confirmed: Bool) async {
        guard let review, !working else { return }
        working = true
        defer { working = false }
        do {
            queued = try await ManagedStorageFiles.remove(review, downloads: environment.githubUpdateDownloads, confirmed: confirmed)
        } catch {
            self.error = error.localizedDescription
            await reloadReview()
        }
    }
}

extension Notification.Name {
    static let sideKickStorageDidChange = Notification.Name("SideKick.StorageDidChange")
}
