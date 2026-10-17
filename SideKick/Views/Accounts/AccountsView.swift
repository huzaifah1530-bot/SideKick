import SwiftUI
import SideSign

struct AccountsView: View {
    let showsNavigationStack: Bool
    @State private var accountStore = SigningAccountStore()
    @State private var hasLoadedAccounts = false
    @State private var errorMessage: String?
    @State private var isShowingSignIn = false
    @State private var isShowingDiagnostics = false
    @State private var submittedCredentials: (appleID: String, password: String)?

    init(showsNavigationStack: Bool = false) {
        self.showsNavigationStack = showsNavigationStack
    }

    var body: some View {
        if showsNavigationStack {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if accountStore.isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Adding Apple Account")
                                .font(.subheadline.weight(.medium))
                            if let checkpoint = accountStore.signInCheckpoint {
                                Text(friendlySignInCheckpoint(checkpoint))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let loadError = accountStore.loadError {
                Section {
                    Label("Couldn’t Load Accounts", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                    SwiftUI.Button("Try Again") { Task { await accountStore.reload() } }
                }
            }
            if !hasLoadedAccounts && accountStore.accounts.isEmpty {
                ProgressView("Loading Apple Accounts…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if accountStore.accounts.isEmpty && accountStore.loadError == nil && !accountStore.isWorking {
                ContentUnavailableView {
                    Label("No Apple Accounts", systemImage: "person.crop.circle")
                } description: {
                    Text("Add an Apple Account to sign and install apps.")
                } actions: {
                    SwiftUI.Button { isShowingSignIn = true } label: {
                        Text("Add Apple Account").font(.headline).padding(.horizontal, Spacing.m)
                    }
                    .primaryActionStyle()
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(accountStore.accounts) { account in
                        NavigationLink {
                            SigningAccountDetailView(account: account, accountStore: accountStore)
                        } label: {
                            accountRow(account)
                        }
                    }
                } footer: {
                    Text("Apps are signed with these accounts. Passwords are stored in the iOS Keychain.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button {
                    isShowingSignIn = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Apple Account")
                .disabled(accountStore.isWorking)
            }
        }
        .task {
            await accountStore.reload()
            hasLoadedAccounts = true
        }
        .refreshable { await accountStore.reload() }
        .sheet(isPresented: $isShowingSignIn, onDismiss: beginSignIn) {
            AppleIDSignInSheet { appleID, password in
                submittedCredentials = (appleID, password)
            }
        }
        .alert("Couldn’t Add Apple Account", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("Diagnostics") { errorMessage = nil; isShowingDiagnostics = true }
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            NavigationStack {
                DiagnosticsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SwiftUI.Button("Done") { isShowingDiagnostics = false }
                        }
                    }
            }
        }
    }

    private func accountRow(_ account: SigningAccountSummary) -> some View {
        let needsSignIn = !account.hasSavedSession || account.rawTeamType == nil
        return HStack(spacing: Spacing.s) {
            AccountAvatar(email: account.email, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(needsSignIn ? "Sign in required" : (account.teamName.isEmpty ? account.teamType : "\(account.teamName) · \(account.teamType)"))
                    .font(.subheadline)
                    .foregroundStyle(needsSignIn ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if needsSignIn {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
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

    private func friendlySignInCheckpoint(_ checkpoint: String) -> String {
        switch checkpoint {
        case "Starting Apple ID authentication": "Connecting to Apple"
        case "Apple authentication succeeded; resolving developer team": "Finding your developer team"
        case "Apple ID authenticated; saving its signing session": "Saving your sign-in"
        case "Session saved; refreshing the account list": "Updating your accounts"
        case "Apple ID authenticated; preparing this device for signing": "Preparing this device for signing"
        default: "Finishing Apple ID sign-in"
        }
    }
}

struct SigningAccountDetailView: View {
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    var forceReconnect = false
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isConfirmingRemoval = false
    @State private var inventory: AppleDeveloperInventory?
    @State private var inventoryError: String?
    @State private var isLoadingInventory = false
    @State private var isShowingReconnect = false
    @State private var reconnectCredentials: (appleID: String, password: String)?

    private var currentAccount: SigningAccountSummary {
        accountStore.accounts.first(where: { $0.id == account.id }) ?? account
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Spacing.s) {
                    AccountAvatar(email: currentAccount.email, size: 88)
                    VStack(spacing: Spacing.xxs) {
                        Text(currentAccount.email)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        Text([currentAccount.teamName, currentAccount.teamType].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if needsReconnect {
                        SwiftUI.Button { isShowingReconnect = true } label: {
                            ActionLabel("Sign In Again", systemImage: "person.crop.circle.badge.checkmark", isWorking: accountStore.isWorking)
                        }
                        .primaryActionStyle()
                        .disabled(accountStore.isWorking)
                        .padding(.top, Spacing.xs)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
            }
            .listRowBackground(Color.clear)

            if currentAccount.hasSavedSession, currentAccount.isFreeAccount, let inventory {
                Section {
                    let remaining = max(10 - inventory.appIDs.count, 0)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(remaining)")
                                .font(.title.weight(.bold).monospacedDigit())
                            Text("of 10 App IDs left")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Gauge(value: Double(remaining), in: 0...10) { EmptyView() }
                            .gaugeStyle(.linearCapacity)
                            .tint(remaining <= 2 ? Color.orange : Color.sideKickAccent)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(remaining) of 10 App IDs left")
                } footer: {
                    Text("Free accounts can register 10 App IDs per week. Each app and extension uses one.")
                }
            }

            SwiftUI.Section {
                if !currentAccount.hasSavedSession {
                    Text("Sign in again to check App IDs, profiles, and certificates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let inventory {
                    NavigationLink {
                        AccountAppIDListView(appIDs: inventory.appIDs)
                    } label: {
                        LabeledContent("App IDs", value: "\(inventory.appIDs.count)")
                    }
                    NavigationLink {
                        AccountProfileListView(profiles: inventory.profiles)
                    } label: {
                        LabeledContent("Profiles", value: "\(inventory.profiles.count)")
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
                Text("Developer Resources")
            }

            Section {
                SwiftUI.Button("Remove Account", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(accountStore.isWorking)
            } footer: {
                Text("Installed apps stay on your iPhone.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Apple Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingReconnect, onDismiss: reconnect) {
            AppleIDSignInSheet { appleID, password in reconnectCredentials = (appleID, password) }
        }
        .task { await loadInventory() }
        .refreshable { await loadInventory() }
        .confirmationDialog("Remove this Apple Account?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Account", role: .destructive) {
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
            Text("Its saved sign-in is removed from this iPhone. Installed apps aren’t deleted.")
        }
        .alert("Apple Account", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var needsReconnect: Bool {
        forceReconnect || !currentAccount.hasSavedSession || currentAccount.rawTeamType == nil
    }

    private func reconnect() {
        guard let credentials = reconnectCredentials else { return }
        reconnectCredentials = nil
        Task {
            do {
                guard credentials.appleID.caseInsensitiveCompare(account.email) == .orderedSame else {
                    errorMessage = "Sign in with \(account.email) to reconnect this account. To use a different account, add it from Accounts."
                    return
                }
                try await accountStore.addAccount(appleID: credentials.appleID, password: credentials.password)
                await loadInventory()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadInventory() async {
        guard currentAccount.hasSavedSession, currentAccount.rawTeamType != nil else { return }
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
