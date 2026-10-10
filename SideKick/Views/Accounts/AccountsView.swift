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
                                    .fullWidthListSeparators()
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

            SwiftUI.Section {
                if !currentAccount.hasSavedSession {
                    Text("Sign in again to check App IDs, profiles, and certificates.")
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
                    NavigationLink {
                        AccountCertificateListView(
                            account: currentAccount,
                            accountStore: accountStore,
                            certificates: inventory.certificates
                        ) { updatedCertificates in
                            self.inventory = AppleDeveloperInventory(
                                appIDs: inventory.appIDs,
                                profiles: inventory.profiles,
                                certificates: updatedCertificates
                            )
                        }
                    } label: {
                        LabeledContent("Certificates", value: "\(inventory.certificates.count)")
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
            } header: {
                Text("Apple Developer")
            } footer: {
                Text("Live Apple Developer records; profiles and certificates don’t prove an app is installed.")
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
                        Text("\(profile.dateExpire <= .now ? "Expired" : "Expires \(profile.dateExpire.formatted(.relative(presentation: .numeric)))") · \(profile.dateExpire.formatted(date: .abbreviated, time: .omitted))")
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

private struct AccountCertificateListView: View {
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let onCertificatesChanged: ([ALTX509Certificate]) -> Void
    @State private var certificates: [ALTX509Certificate]
    @State private var certificateToRevoke: ALTX509Certificate?
    @State private var errorMessage: String?
    @State private var isWorking = false

    init(
        account: SigningAccountSummary,
        accountStore: SigningAccountStore,
        certificates: [ALTX509Certificate],
        onCertificatesChanged: @escaping ([ALTX509Certificate]) -> Void
    ) {
        self.account = account
        self.accountStore = accountStore
        self.onCertificatesChanged = onCertificatesChanged
        _certificates = State(initialValue: certificates)
    }

    private var sortedCertificates: [ALTX509Certificate] {
        certificates.sorted { $0.expiryDate < $1.expiryDate }
    }

    var body: some View {
        List {
            if certificates.isEmpty {
                ContentUnavailableView(
                    "No Certificates",
                    systemImage: "checkmark.seal",
                    description: Text("This Apple Developer team has no certificates.")
                )
            } else {
                Section {
                    ForEach(sortedCertificates, id: \.serialNumber) { certificate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(certificate.name)
                                    .font(.body.weight(.medium))
                                Spacer(minLength: 8)
                                Text(certificate.expiryDate <= .now ? "Expired" : "Active")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(certificate.expiryDate <= .now ? .red : .green)
                            }
                            if let machineName = certificate.machineName, !machineName.isEmpty {
                                Text(machineName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Expires \(certificate.expiryDate.formatted(date: .abbreviated, time: .omitted)) · Serial \(certificate.serialNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            SwiftUI.Button(role: .destructive) {
                                certificateToRevoke = certificate
                            } label: {
                                Label("Revoke Certificate", systemImage: "xmark.bin")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isWorking)
                        }
                        .padding(.vertical, 5)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SwiftUI.Button(role: .destructive) {
                                certificateToRevoke = certificate
                            } label: {
                                Label("Revoke", systemImage: "xmark.bin")
                            }
                            .disabled(isWorking)
                        }
                    }
                } footer: {
                    Text("Revoking a certificate is permanent and may affect apps signed with it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Certificates")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reloadCertificates() }
        .confirmationDialog(
            "Revoke this certificate?",
            isPresented: Binding(
                get: { certificateToRevoke != nil },
                set: { if !$0 { certificateToRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            SwiftUI.Button("Revoke Certificate", role: .destructive) {
                guard let certificate = certificateToRevoke else { return }
                certificateToRevoke = nil
                Task { await revoke(certificate) }
            }
            SwiftUI.Button("Cancel", role: .cancel) { certificateToRevoke = nil }
        } message: {
            Text("This removes it from Apple’s developer portal. Apps or profiles that depend on it may stop working.")
        }
        .alert("Couldn’t manage certificate", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reloadCertificates() async {
        do {
            certificates = try await accountStore.fetchDeveloperCertificates(for: account)
            onCertificatesChanged(certificates)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ certificate: ALTX509Certificate) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard try await accountStore.revokeDeveloperCertificate(certificate, for: account) else {
                errorMessage = "Apple didn’t revoke this certificate. Refresh the list and try again."
                return
            }
            certificates.removeAll { $0.serialNumber == certificate.serialNumber }
            onCertificatesChanged(certificates)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
