import SwiftUI

struct StorageFilesView: View {
    @State private var items: [RemovableStorageItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Signing sources let SideKick refresh apps without downloading them again. You can remove them to reclaim space, but may need to import the original IPA before the next refresh. SideKick automatically cleans completed install files. Recent recovery sources and temporary files in use stay protected.")
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
                        if let reason = item.protectedReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                        else if item.policy.requiresSourceConfirmation { Text("Retained for app refresh; removable with confirmation.").font(.footnote).foregroundStyle(.secondary) }
                    }
                    if item.protectedReason == nil { StorageRemovalAction(item: item) }
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
    @Environment(AppEnvironment.self) private var environment
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SwiftUI.Button(role: .destructive) { confirming = true } label: {
            Label(item.policy.requiresSourceConfirmation ? "Remove Cached Source" : "Delete File", systemImage: "trash")
        }
        .disabled(working)
        .alert(item.policy.requiresSourceConfirmation ? "Remove cached app source?" : "Delete this file?", isPresented: $confirming) {
            SwiftUI.Button("Delete", role: .destructive) { Task { await remove() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text(item.policy.requiresSourceConfirmation
                ? "This removes the extracted source for \(item.policy.owner ?? "this app"). The installed app and its records stay in place. Refresh may require importing its original IPA again."
                : "This removes \(item.url.lastPathComponent) from SideKick and reclaims \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).")
        }
        .alert("Storage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @MainActor private func remove() async {
        working = true
        defer { working = false }
        do {
            try await SideKickStorageCleanup.remove(item, downloads: environment.githubUpdateDownloads, allowRetainedSource: item.policy.requiresSourceConfirmation)
            NotificationCenter.default.post(name: .sideKickStorageDidChange, object: nil)
        } catch { self.error = error.localizedDescription }
    }
}

extension Notification.Name {
    static let sideKickStorageDidChange = Notification.Name("SideKick.StorageDidChange")
}
