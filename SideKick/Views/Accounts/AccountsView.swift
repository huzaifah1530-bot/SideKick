import SwiftUI

struct AccountsView: View {
    @State private var accountStore = SigningAccountStore()
    @State private var errorMessage: String?
    @State private var isShowingSignIn = false
    @State private var submittedCredentials: (appleID: String, password: String)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Choose a signing account", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                        Text("Add Apple IDs here, then choose which one SideKick should use as its active signing account. Each saved session is kept separately in the iOS Keychain.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Initial Apple device registration may require the one-time computer pairing setup. LocalDevVPN is a separate app and must be installed and connected when SideStore’s device workflow requires it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Adding an Apple ID now saves its session first. Device registration and certificate setup are deferred so they can’t block account sign-in.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)

                    SwiftUI.Button {
                        isShowingSignIn = true
                    } label: {
                        Label(accountStore.isWorking ? "Connecting…" : "Add Apple ID", systemImage: "plus.circle.fill")
                    }
                    .disabled(accountStore.isWorking)
                }

                Section("Saved Apple IDs") {
                    if accountStore.accounts.isEmpty {
                        ContentUnavailableView(
                            "No Apple IDs yet",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("Add an Apple ID to begin setting up SideKick’s signing engine.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(accountStore.accounts) { account in
                            accountRow(account)
                        }
                    }
                }

                if let signInCheckpoint = accountStore.signInCheckpoint {
                    Section("Sign-in status") {
                        Label(signInCheckpoint, systemImage: signInCheckpoint == "Account saved successfully" ? "checkmark.circle" : "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label("Install and refresh use SideStore", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("SideKick routes installs through the Apple ID you choose and refreshes each app with the account recorded by SideStore. Real-device signing and refresh still need device testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sideKickCanvas)
            .navigationTitle("Apple IDs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button {
                        Task { await accountStore.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(accountStore.isWorking)
                    .accessibilityLabel("Reload Apple IDs")
                }
            }
            .task { await accountStore.reload() }
            .refreshable { await accountStore.reload() }
            .sheet(isPresented: $isShowingSignIn, onDismiss: beginSignIn) {
                AppleIDSignInSheet { appleID, password in
                    submittedCredentials = (appleID, password)
                }
            }
            .alert("Couldn’t update Apple IDs", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                    SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func beginSignIn() {
        guard let submittedCredentials else { return }
        self.submittedCredentials = nil
        Task {
            do {
                try await accountStore.addAccount(
                    appleID: submittedCredentials.appleID,
                    password: submittedCredentials.password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: SigningAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(account.teamName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                if account.isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack {
                Text(account.teamType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !account.isActive {
                    SwiftUI.Button("Use for signing") {
                        Task {
                            do {
                                try await accountStore.activate(account)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(accountStore.isWorking || !account.hasSavedSession)
                }
            }

            if !account.hasSavedSession {
                Text("Sign in again to save this account’s session on this device.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 5)
    }
}
