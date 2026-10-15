import SwiftUI

struct DiagnosticsView: View {
    @State private var entries: [DiagnosticsStore.Entry] = []
    @State private var persistenceFailed = false
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                Text("Authentication, Anisette, signing, installation, refresh, local connection and GitHub events. Logs contain stages and codes, without credentials, account details, URLs, headers or response bodies. Logs stay on this device unless you share them.")
                    .font(.footnote).foregroundStyle(.secondary)
                if persistenceFailed {
                    Label("Recent events are available, but could not be saved on this device.", systemImage: "exclamationmark.triangle")
                }
                NavigationLink("GitHub Update Logs") { GitHubDiagnosticsView() }
            }
            if entries.isEmpty {
                ContentUnavailableView("No Diagnostics Yet", systemImage: "list.bullet.clipboard", description: Text("Try the operation again, then return here to see its stages and error codes."))
            } else {
                Section {
                    ShareLink(item: DiagnosticsStore.export(entries)) { Label("Share Diagnostics", systemImage: "square.and.arrow.up") }
                    SwiftUI.Button("Clear Diagnostics", role: .destructive) { confirmingClear = true }
                }
                Section("Recent activity") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(entry.operation.title) · \(entry.stage.title) · \(entry.event.rawValue.capitalized)").fontWeight(.medium)
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                            if !entry.details.isEmpty { Text(entry.details).font(.footnote).textSelection(.enabled) }
                            if entry.event == .failed || (entry.code != nil && entry.code != 0) || (entry.httpStatus ?? 0) >= 400 {
                                Text(entry.stage.help).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(entry.operationID.uuidString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .task {
            while !Task.isCancelled {
                reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .confirmationDialog("Clear general diagnostics?", isPresented: $confirmingClear, titleVisibility: .visible) {
            SwiftUI.Button("Clear Diagnostics", role: .destructive) { DiagnosticsStore.shared.clear(); reload() }
        } message: { Text("This removes the general diagnostic history. GitHub’s detailed update logs can be cleared on their own screen.") }
    }

    private func reload() {
        let snapshot = DiagnosticsStore.shared.snapshot()
        entries = snapshot.entries
        persistenceFailed = snapshot.persistenceFailed
    }
}
