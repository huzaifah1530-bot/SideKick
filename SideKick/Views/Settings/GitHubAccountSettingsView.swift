import SwiftUI

struct GitHubAccountSettingsView: View {
    @State private var credentials: [GitHubCredentialStore.Credential] = []
    @State private var defaultID: String?
    @State private var errorMessage: String?

    @State private var isShowingSignIn = false
    @State private var isConfirmingSignOut = false
    private var account: GitHubCredentialStore.Credential? { credentials.first(where: \.isGitHubAccount) }
    private var tokens: [GitHubCredentialStore.Credential] { credentials.filter { !$0.isGitHubAccount } }

    var body: some View {
        List {
            Section {
                if let account {
                    HStack(spacing: Spacing.s) {
                        AccountAvatar(kind: .github, id: account.username, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.username.isEmpty ? "GitHub Account" : "@\(account.username)")
                                .font(.body.weight(.semibold))
                            Text(defaultID == account.id ? "Signed in · Default" : "Signed in")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    if let installURL = GitHubAppConfiguration.installURL {
                        Link(destination: installURL) {
                            Label("Choose Private Repositories…", systemImage: "lock.open")
                        }
                    }
                    if defaultID != account.id {
                        SwiftUI.Button("Use as Default") {
                            do { try GitHubCredentialStore().setDefault(account.id); reload() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    SwiftUI.Button("Sign Out", role: .destructive) { isConfirmingSignOut = true }
                } else {
                    SwiftUI.Button { isShowingSignIn = true } label: {
                        Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.plus")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(!GitHubAppConfiguration.isConfigured)
                }
            } header: {
                Text("GitHub Account")
            } footer: {
                if !GitHubAppConfiguration.isConfigured {
                    Text("GitHub sign-in isn’t set up in this build yet. You can still use tokens below.")
                } else if account == nil {
                    Text("Read-only access to any public repository. To include your private repositories, choose them after signing in.")
                } else {
                    Text("Read-only. Private repositories are included once you choose them on GitHub.")
                }
            }

            Section {
                ForEach(tokens) { credential in
                    NavigationLink {
                        GitHubTokenEditorView(credential: credential)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(credential.label)
                                    Text(credential.username.isEmpty ? "Saved token" : "@\(credential.username)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "key.fill") }
                            Spacer()
                            if defaultID == credential.id {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink {
                    GitHubTokenEditorView(credential: nil)
                } label: { Label("Add Token", systemImage: "plus.circle") }
            } header: { Text("Tokens") } footer: {
                Text("Optional. Use a token for repositories the GitHub account can’t reach. Stored in the iOS Keychain.")
            }
            Section {
                NavigationLink {
                    GitHubDefaultTokenSettingsView(selection: $defaultID) { value in
                        try GitHubCredentialStore().setDefault(value)
                    }
                } label: {
                    LabeledContent("Default Token", value: credentials.first { $0.id == defaultID }?.label ?? "Public access")
                }
            }
            Section {
                Link("Create a GitHub token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                Text("For private repositories, select the repository’s owner and include the repository. Grant Contents: read for releases and Actions: read for builds. Organization tokens may need approval.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSignIn, onDismiss: reload) { GitHubSignInSheet() }
        .confirmationDialog("Sign out of GitHub?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            SwiftUI.Button("Sign Out", role: .destructive) {
                do { try GitHubAccountSession.signOut(); reload() }
                catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Apps set to use your GitHub account fall back to public access until you sign in again or choose a token.")
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            reload()
        }
    }

    private func reload() {
        do {
            credentials = try GitHubCredentialStore().all()
            defaultID = try GitHubCredentialStore().defaultID()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct GitHubTokenEditorView: View {
    @State private var credential: GitHubCredentialStore.Credential?
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var savedLabel = ""

    init(credential: GitHubCredentialStore.Credential?) {
        _credential = State(initialValue: credential)
        _label = State(initialValue: credential?.label ?? "")
        _savedLabel = State(initialValue: credential?.label ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Personal or Work", text: $label)
                SecureField(credential == nil ? "GitHub token" : "Replacement token (optional)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let credential, !credential.username.isEmpty {
                    LabeledContent("GitHub Account", value: "@\(credential.username)")
                }
            } header: { Text("Token Details") } footer: {
                Text("The name helps you choose the right token for each repository. Leave the replacement token empty to keep the current one.")
            }
            Section {
                SwiftUI.Button { Task { if await save() { dismiss() } } } label: {
                    HStack { Text("Save Token"); Spacer(); if isSaving { ProgressView() } }
                }
                .disabled(isSaving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (credential == nil && token.isEmpty))
                if credential != nil {
                    SwiftUI.Button("Delete Token", role: .destructive) { confirmingDelete = true }
                        .disabled(isSaving)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle(credential == nil ? "Add GitHub Token" : "Edit GitHub Token")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .guardUnsavedSettings(isDirty: label != savedLabel || !token.isEmpty, save: {
            await save()
        }, discard: { label = savedLabel; token = "" })
        .alert("Delete this token?", isPresented: $confirmingDelete) {
            SwiftUI.Button("Delete Token", role: .destructive) {
                do { if let credential { try GitHubCredentialStore().delete(id: credential.id) }; dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Apps using this token will need another token selected in their GitHub update settings.") }
    }

    @MainActor private func save() async -> Bool {
        guard !isSaving else { return false }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential != nil || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a name and a GitHub token before saving."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedToken = value.isEmpty ? credential?.token ?? "" : value
            let username: String
            if value.isEmpty, let credential {
                username = credential.username
            } else {
                username = try await GitHubUpdateService().validateToken(savedToken)
            }
            try GitHubCredentialStore().save(label: label.trimmingCharacters(in: .whitespacesAndNewlines), username: username, token: savedToken, id: credential?.id)
            credential = try GitHubCredentialStore().all().last
            label = credential?.label ?? label
            savedLabel = label
            token = ""
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

struct GitHubTokenSelectionLink: View {
    @Binding var selection: String?
    @State private var label = "Use Default Token"
    var body: some View {
        NavigationLink { GitHubTokenPickerView(selection: $selection) } label: {
            Label { LabeledContent("GitHub Token", value: label) } icon: { Image(systemName: "key") }
        }
        .fullWidthListSeparators()
        .onAppear { reload() }
        .onChange(of: selection) { _, _ in reload() }
    }
    private func reload() {
        if selection == GitHubCredentialStore.publicAccessID { label = "Public Access"; return }
        if selection == GitHubAccountSession.credentialID {
            label = GitHubAccountSession.account.map { $0.username.isEmpty ? "GitHub Account" : "@\($0.username)" } ?? "Signed Out"
            return
        }
        guard let selection else { label = "Use Default Token"; return }
        do { label = try GitHubCredentialStore().all().first { $0.id == selection }?.label ?? "Token Removed" }
        catch { label = "Token Unavailable" }
    }
}
