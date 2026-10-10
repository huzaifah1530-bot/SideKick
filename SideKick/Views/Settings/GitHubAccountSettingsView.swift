import SwiftUI

struct GitHubAccountSettingsView: View {
    @State private var credentials: [GitHubCredentialStore.Credential] = []
    @State private var defaultID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(credentials) { credential in
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
                Text("Give each token a name. Tokens are stored in iOS Keychain. Each app can use its own token, and you can choose another when downloading.")
            }
            Section {
                NavigationLink {
                    GitHubTokenPickerView(selection: $defaultID, includesDefault: false)
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
        .navigationTitle("GitHub Tokens")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: defaultID) { _, value in
            do { try GitHubCredentialStore().setDefault(value) }
            catch { errorMessage = error.localizedDescription }
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
    let credential: GitHubCredentialStore.Credential?
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

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
                SwiftUI.Button { Task { await save() } } label: {
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
        .onAppear { label = credential?.label ?? "" }
        .alert("Delete this token?", isPresented: $confirmingDelete) {
            SwiftUI.Button("Delete Token", role: .destructive) {
                do { if let credential { try GitHubCredentialStore().delete(id: credential.id) }; dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Apps using this token will need another token selected in their GitHub update settings.") }
    }

    @MainActor private func save() async {
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
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct GitHubTokenPickerView: View {
    @Binding var selection: String?
    var includesDefault = true
    @Environment(\.dismiss) private var dismiss
    @State private var credentials: [GitHubCredentialStore.Credential] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if includesDefault { row("Use Default Token", subtitle: "Uses the default in Settings", id: nil, symbol: "key") }
                row("Public Access", subtitle: "No token; public releases only", id: includesDefault ? GitHubCredentialStore.publicAccessID : nil, symbol: "globe")
                ForEach(credentials) { credential in
                    row(credential.label, subtitle: credential.username.isEmpty ? "Saved token" : "@\(credential.username)", id: credential.id, symbol: "key.fill")
                }
            }
            Section {
                NavigationLink { GitHubAccountSettingsView() } label: {
                    Label("Manage GitHub Tokens", systemImage: "person.crop.circle.badge.plus")
                }
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
        guard let selection else { label = "Use Default Token"; return }
        do { label = try GitHubCredentialStore().all().first { $0.id == selection }?.label ?? "Token Removed" }
        catch { label = "Token Unavailable" }
    }
}
