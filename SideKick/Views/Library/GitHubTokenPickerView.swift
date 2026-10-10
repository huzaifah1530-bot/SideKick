import SwiftUI

struct GitHubTokenPickerView: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var credentials: [GitHubCredentialStore.Credential] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                row("Use Default Token", subtitle: "Uses the default in Settings", id: nil, symbol: "key")
                row("Public Access", subtitle: "No token; public releases only", id: GitHubCredentialStore.publicAccessID, symbol: "globe")
                ForEach(credentials) { credential in
                    row(credential.label, subtitle: credential.username.isEmpty ? "Saved token" : "@\(credential.username)", id: credential.id, symbol: "key.fill")
                }
            }
            Section {
                Text("Add or edit tokens in Settings → GitHub Tokens.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Choose GitHub Token")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do { credentials = try GitHubCredentialStore().all() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func row(_ title: String, subtitle: String, id: String?, symbol: String) -> some View {
        SwiftUI.Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).foregroundStyle(.primary)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: symbol) }
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .fullWidthListSeparators()
    }
}
