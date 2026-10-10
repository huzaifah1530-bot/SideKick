import SwiftUI

struct GitHubAccountSettingsView: View {
    @State private var token = ""
    @State private var hasSavedToken = false
    @State private var username: String?
    @State private var isSaving = false
    @State private var message: String?
    @State private var showingMessage = false

    private let credentialStore = GitHubCredentialStore()

    var body: some View {
        Form {
            Section {
                SecureField("Fine-grained personal access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if hasSavedToken {
                    Label(username.map { "Connected as \($0)" } ?? "GitHub token saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    SwiftUI.Button("Remove GitHub account", role: .destructive) {
                        do {
                            try credentialStore.delete()
                            token = ""
                            hasSavedToken = false
                            message = "GitHub account removed. Public repositories can still be checked without signing in."
                        } catch { message = error.localizedDescription }
                        showingMessage = true
                    }
                }
                SwiftUI.Button {
                    Task { await saveToken() }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save GitHub token") }
                }
                .disabled(isSaving || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("GitHub account")
            } footer: {
                Text("Optional for public repositories. For a private repository, create the token for the repository’s owner, include that repository, and grant Contents: read. Actions: read is also required for Actions builds. Organization tokens may need approval. SideKick stores the token in iOS Keychain and sends it only to api.github.com.")
            }

            Section {
                Link("Create a GitHub token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            }
        }
        .navigationTitle("GitHub Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let saved = try credentialStore.load()
                hasSavedToken = saved != nil
                if let saved { username = try await GitHubUpdateService().validateToken(saved) }
            } catch { message = error.localizedDescription; showingMessage = true }
        }
        .alert("GitHub account", isPresented: $showingMessage) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    @MainActor
    private func saveToken() async {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { message = GitHubTokenInputError.empty.localizedDescription; showingMessage = true; return }
        isSaving = true
        defer { isSaving = false }
        do {
            username = try await GitHubUpdateService().validateToken(value)
            try credentialStore.save(value)
            token = ""
            hasSavedToken = true
            message = "Connected to GitHub as @\(username ?? "user"). The token is stored in iOS Keychain."
        } catch { message = error.localizedDescription }
        showingMessage = true
    }
}

private enum GitHubTokenInputError: LocalizedError {
    case empty
    var errorDescription: String? { "Paste a GitHub token first." }
}
