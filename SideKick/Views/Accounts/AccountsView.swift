import SwiftUI
import SideSign

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
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isConfirmingRemoval = false
    @State private var inventory: AppleDeveloperInventory?
    @State private var inventoryError: String?
    @State private var isLoadingInventory = false

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
                if !currentAccount.hasSavedSession {
                    Text("Sign in again to use this account on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Apple Developer") {
                if !currentAccount.hasSavedSession {
                    Text("Sign in again to check App IDs and profiles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let inventory {
                    if currentAccount.isFreeAccount {
                        LabeledContent(
                            "App IDs available",
                            value: "\(max(10 - inventory.appIDs.count, 0)) of 10"
                        )
                    }
                    NavigationLink {
                        AccountAppIDListView(appIDs: inventory.appIDs)
                    } label: {
                        LabeledContent("Registered App IDs", value: "\(inventory.appIDs.count)")
                    }
                    NavigationLink {
                        AccountProfileListView(profiles: inventory.profiles)
                    } label: {
                        LabeledContent("Provisioning Profiles", value: "\(inventory.profiles.count)")
                    }
                } else if isLoadingInventory {
                    ProgressView("Loading account details")
                } else if let inventoryError {
                    Text(inventoryError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Account details are unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("This is the live Apple Developer account inventory. A profile can remain after its app is removed, so it doesn’t prove the app is installed.")
            }

            Section {
                SwiftUI.Button("Remove Apple ID", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(accountStore.isWorking)
            } footer: {
                Text("This removes the saved account from SideKick. Apps already installed on your iPhone are not deleted.")
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Apple ID")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInventory() }
        .refreshable { await loadInventory() }
        .confirmationDialog("Remove this Apple ID?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Apple ID", role: .destructive) {
                Task {
                    do {
                        try await accountStore.remove(account)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its saved signing session will also be removed from this device.")
        }
        .alert("Couldn’t remove Apple ID", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadInventory() async {
        guard currentAccount.hasSavedSession else { return }
        isLoadingInventory = true
        inventoryError = nil
        defer { isLoadingInventory = false }
        do {
            inventory = try await accountStore.fetchDeveloperInventory(for: currentAccount)
        } catch {
            inventoryError = error.localizedDescription
        }
    }
}

private struct AccountAppIDListView: View {
    let appIDs: [ALTAppID]

    var body: some View {
        List {
            if appIDs.isEmpty {
                ContentUnavailableView("No App IDs", systemImage: "app.dashed")
            } else {
                ForEach(appIDs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { appID in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appID.name.isEmpty ? appID.bundleIdentifier : appID.name)
                            .foregroundStyle(.primary)
                        Text(appID.bundleIdentifier)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let expirationDate = appID.expirationDate {
                            Text("App ID expires \(expirationDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App IDs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountProfileListView: View {
    let profiles: [ALTListedProvisioningProfile]

    var body: some View {
        List {
            if profiles.isEmpty {
                ContentUnavailableView("No Profiles", systemImage: "checkmark.seal")
            } else {
                ForEach(profiles.sorted { $0.dateExpire < $1.dateExpire }) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.appId?.name.flatMap { $0.isEmpty ? nil : $0 } ?? profile.name)
                            .foregroundStyle(.primary)
                        if let bundleIdentifier = profile.bundleIdentifier {
                            Text(bundleIdentifier)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("Expires \(profile.dateExpire.formatted(.relative(presentation: .numeric))) · \(profile.dateExpire.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
