import SwiftUI

struct AccountsView: View {
    @State private var accountStore = SigningAccountStore()
    @State private var errorMessage: String?
    @State private var isShowingSignIn = false
    @State private var submittedCredentials: (appleID: String, password: String)?

    var body: some View {
        NavigationStack {
            List {
                if accountStore.accounts.isEmpty {
                    ContentUnavailableView(
                        "No Apple IDs",
                        systemImage: "person.crop.circle",
                        description: Text("Add an Apple ID to sign and install apps.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Apple IDs") {
                        ForEach(accountStore.accounts) { account in
                            NavigationLink {
                                SigningAccountDetailView(account: account, accountStore: accountStore)
                            } label: {
                                accountRow(account)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Accounts")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button {
                        isShowingSignIn = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Apple ID")
                    .disabled(accountStore.isWorking)
                }
            }
            .task { await accountStore.reload() }
            .refreshable { await accountStore.reload() }
            .sheet(isPresented: $isShowingSignIn, onDismiss: beginSignIn) {
                AppleIDSignInSheet { appleID, password in
                    submittedCredentials = (appleID, password)
                }
            }
            .alert("Couldn’t add Apple ID", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func accountRow(_ account: SigningAccountSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.email)
                    .foregroundStyle(.primary)
                Text(account.teamName.isEmpty ? account.teamType : account.teamName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if account.isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
}

private struct SigningAccountDetailView: View {
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    @State private var errorMessage: String?

    private var currentAccount: SigningAccountSummary {
        accountStore.accounts.first(where: { $0.id == account.id }) ?? account
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Apple ID", value: currentAccount.email)
                LabeledContent("Team", value: currentAccount.teamName)
                LabeledContent("Account type", value: currentAccount.teamType)
            }

            Section {
                if currentAccount.isActive {
                    LabeledContent("Signing account", value: "Active")
                } else {
                    SwiftUI.Button("Use for signing") {
                        Task {
                            do {
                                try await accountStore.activate(account)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(accountStore.isWorking || !currentAccount.hasSavedSession)
                }

                if !currentAccount.hasSavedSession {
                    Text("Sign in again to use this account on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Apple ID")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t switch account", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
