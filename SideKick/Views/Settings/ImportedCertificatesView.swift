import SwiftUI
import UniformTypeIdentifiers

/// Settings → Advanced → Certificates. Lists certificates the user imported from .p12 files.
struct ImportedCertificatesView: View {
    @State private var store = ImportedCertificateStore.shared
    @State private var accountStore = SigningAccountStore()
    @State private var isImporting = false
    @State private var pendingURL: URL?
    @State private var password = ""
    @State private var isAskingForPassword = false
    @State private var passwordWasIncorrect = false
    @State private var recordToDelete: ImportedCertificateRecord?
    @State private var errorMessage: String?
    @State private var importQueue: [URL] = []
    @State private var importFailures: [String] = []
    @State private var lastPassword: String?

    static let importTypes: [UTType] = [
        UTType(filenameExtension: "p12"),
        UTType(filenameExtension: "pfx"),
        UTType("com.rsa.pkcs-12"),
        UTType(filenameExtension: "mobileprovision"),
        UTType("com.apple.mobileprovision")
    ].compactMap { $0 }

    var body: some View {
        List {
            if store.certificates.isEmpty {
                ContentUnavailableView {
                    Label("No Imported Certificates", systemImage: "checkmark.seal")
                } description: {
                    Text("Select the .p12 file and its matching .mobileprovision file together to sign apps with your own certificate.")
                } actions: {
                    SwiftUI.Button("Import Certificate") { isImporting = true }
                }
            } else {
                Section {
                    ForEach(store.certificates) { record in
                        NavigationLink {
                            ImportedCertificateDetailView(record: record, accountStore: accountStore)
                        } label: {
                            ImportedCertificateRow(record: record, usageCount: store.assignedAccountKeys(for: record).count)
                        }
                        .swipeActions {
                            SwiftUI.Button("Delete", role: .destructive) { recordToDelete = record }
                        }
                    }
                } footer: {
                    Text("Import a certificate together with its .mobileprovision file. Select it directly when installing or re-signing an app. No Apple Account sign-in is required.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Certificates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SwiftUI.Button { isImporting = true } label: {
                    Label("Import Certificate", systemImage: "plus")
                }
            }
        }
        .task {
            store.reload()
            await accountStore.reload()
            await store.checkStatuses()
        }
        .refreshable { await store.checkStatuses() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): startImport(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert(passwordWasIncorrect ? "Incorrect Password" : "Certificate Password", isPresented: $isAskingForPassword) {
            SecureField("Password", text: $password)
                .textContentType(.password)
            SwiftUI.Button("Skip", role: .cancel) { skipPasswordFile() }
            SwiftUI.Button("Import") { submitPassword() }
        } message: {
            Text("Enter the password for “\(pendingURL?.lastPathComponent ?? "this file")”.")
        }
        .confirmationDialog(
            "Delete “\(recordToDelete?.name ?? "")”?",
            isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
            titleVisibility: .visible
        ) {
            SwiftUI.Button("Delete Certificate", role: .destructive) {
                if let record = recordToDelete { delete(record) }
            }
            SwiftUI.Button("Cancel", role: .cancel) { recordToDelete = nil }
        } message: {
            Text(deletionMessage)
        }
        .alert("Certificates", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deletionMessage: String {
        "It is removed from this iPhone. Installed apps keep working until they expire, but need this certificate to refresh or update."
    }

    /// Certificates are imported before profiles so each profile can find its certificate.
    private func startImport(_ urls: [URL]) {
        let isProfile = { (url: URL) in url.pathExtension.lowercased() == "mobileprovision" }
        importQueue = urls.filter { !isProfile($0) } + urls.filter(isProfile)
        importFailures = []
        lastPassword = nil
        continueImport()
    }

    private func continueImport() {
        while let url = importQueue.first {
            if url.pathExtension.lowercased() == "mobileprovision" {
                do { try store.importProfile(from: url) }
                catch { importFailures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                importQueue.removeFirst()
                continue
            }
            do {
                do {
                    try store.importCertificate(from: url, password: nil)
                } catch ImportedCertificateError.passwordRequired where lastPassword != nil {
                    // Certificates exported together usually share one password.
                    try store.importCertificate(from: url, password: lastPassword)
                }
                importQueue.removeFirst()
            } catch ImportedCertificateError.passwordRequired {
                askForPassword(for: url, incorrect: false)
                return
            } catch ImportedCertificateError.incorrectPassword {
                askForPassword(for: url, incorrect: false)
                return
            } catch {
                importFailures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                importQueue.removeFirst()
            }
        }
        if !importFailures.isEmpty {
            errorMessage = importFailures.joined(separator: "\n\n")
            importFailures = []
        }
    }

    private func submitPassword() {
        guard let url = pendingURL else { return }
        do {
            try store.importCertificate(from: url, password: password)
            lastPassword = password
            importQueue.removeFirst()
            resetPasswordPrompt()
            continueImport()
        } catch ImportedCertificateError.incorrectPassword {
            askForPassword(for: url, incorrect: true)
        } catch {
            importFailures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            importQueue.removeFirst()
            resetPasswordPrompt()
            continueImport()
        }
    }

    private func skipPasswordFile() {
        if let url = pendingURL {
            importFailures.append("\(url.lastPathComponent): Skipped because no password was entered.")
            importQueue.removeFirst()
        }
        resetPasswordPrompt()
        continueImport()
    }

    private func askForPassword(for url: URL, incorrect: Bool) {
        pendingURL = url
        passwordWasIncorrect = incorrect
        password = ""
        // Re-present on the next run loop so a dismissed alert can show again.
        DispatchQueue.main.async { isAskingForPassword = true }
    }

    private func resetPasswordPrompt() {
        pendingURL = nil
        password = ""
        passwordWasIncorrect = false
    }

    private func delete(_ record: ImportedCertificateRecord) {
        recordToDelete = nil
        do { try store.delete(record) } catch { errorMessage = error.localizedDescription }
    }
}

struct ImportedCertificateRow: View {
    let record: ImportedCertificateRecord
    let usageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if record.isRevoked {
                    Text("Revoked")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                } else if record.effectiveExpiryDate <= .now {
                    Text("Expired")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let date = record.effectiveExpiryDate
        let expiry = "\(date <= .now ? "Expired" : "Expires") \(date.formatted(date: .abbreviated, time: .omitted))"
        var parts = [expiry]
        if record.profile == nil { parts.append("No profile") }
        if let profile = record.profile { parts.append(profile.teamIdentifier) }
        return parts.joined(separator: " · ")
    }
}

struct ImportedCertificateDetailView: View {
    let record: ImportedCertificateRecord
    let accountStore: SigningAccountStore
    @State private var store = ImportedCertificateStore.shared
    @State private var isConfirmingDeletion = false
    @State private var errorMessage: String?
    @State private var isImportingProfile = false
    @Environment(\.dismiss) private var dismiss

    /// Live copy, so a newly paired profile shows without leaving the page.
    private var current: ImportedCertificateRecord {
        store.catalog.record(serialNumber: record.serialNumber) ?? record
    }

    private var statusText: String {
        if current.isRevoked { return "Revoked" }
        if current.effectiveExpiryDate <= .now { return "Expired" }
        switch current.status {
        case .valid?: return "Valid"
        case .unknown?: return "Couldn’t check"
        case nil: return "Not checked"
        case .revoked?: return "Revoked"
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: record.name)
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(current.isRevoked || current.effectiveExpiryDate <= .now ? .red : .secondary)
                }
                LabeledContent("Issued", value: record.issueDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Expires", value: record.expiryDate.formatted(date: .abbreviated, time: .omitted))
                if let profile = current.profile, profile.expirationDate < record.expiryDate {
                    LabeledContent("Apps Stop Opening", value: profile.expirationDate.formatted(date: .abbreviated, time: .omitted))
                }
                SwiftUI.Button {
                    Task { await store.checkStatuses() }
                } label: {
                    HStack {
                        Text("Check Status")
                        if store.isCheckingStatus { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.isCheckingStatus)
            } footer: {
                if let checked = current.statusCheckedAt {
                    Text("Checked with Apple \(checked.formatted(.relative(presentation: .named))).")
                }
            }

            Section("Details") {
                LabeledContent("Serial Number") {
                    Text(record.serialNumber)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("File", value: record.fileName)
                LabeledContent("Imported", value: record.importedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                if let profile = current.profile {
                    LabeledContent("Name", value: profile.name)
                    LabeledContent("App ID", value: profile.appIdentifier)
                    LabeledContent("Team", value: profile.teamName.isEmpty ? profile.teamIdentifier : "\(profile.teamName) (\(profile.teamIdentifier))")
                    LabeledContent("Devices", value: "\(profile.deviceCount)")
                    LabeledContent("Expires") {
                        Text(profile.expirationDate.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(profile.isExpired() ? .red : .secondary)
                    }
                    SwiftUI.Button("Replace Profile") { isImportingProfile = true }
                    SwiftUI.Button("Remove Profile", role: .destructive) {
                        do { try store.removeProfile(from: current) } catch { errorMessage = error.localizedDescription }
                    }
                } else {
                    SwiftUI.Button {
                        isImportingProfile = true
                    } label: {
                        Label("Add Provisioning Profile", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Provisioning Profile")
            } footer: {
                if current.profile == nil {
                    Text("Certificates need the matching .mobileprovision file they came with. It must include this iPhone.")
                } else {
                    Text("Apps signed with this profile share one Keychain, so each can read logins the others save there. Only sign apps you trust with it.")
                }
            }

            Section("Signing") {
                Text("Choose this certificate directly when installing or re-signing. Its signing team comes from its provisioning profile; no Apple Account sign-in is needed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                SwiftUI.Button("Delete Certificate", role: .destructive) { isConfirmingDeletion = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImportingProfile,
            allowedContentTypes: [UTType(filenameExtension: "mobileprovision"), UTType("com.apple.mobileprovision")].compactMap { $0 }
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let paired = try store.importProfile(from: url)
                    if paired.serialNumber.caseInsensitiveCompare(record.serialNumber) != .orderedSame {
                        errorMessage = "That profile belongs to “\(paired.name)”, so it was added there instead."
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Delete “\(record.name)”?", isPresented: $isConfirmingDeletion, titleVisibility: .visible) {
            SwiftUI.Button("Delete Certificate", role: .destructive) {
                do {
                    try store.delete(record)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("It is removed from this iPhone. Installed apps keep working until they expire, but need this certificate to refresh or update.")
        }
        .alert("Certificate", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// Shown before re-signing an app with an imported certificate from another team.
struct ImportedCertificateResignWarningView<Destination: View>: View {
    let appName: String
    let isSideKick: Bool
    let record: ImportedCertificateRecord
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        List {
            Section {
                Label {
                    Text("Re-signing replaces \(appName)’s signature with “\(record.name)”. This can’t be undone. Switching back means re-signing again with your Apple certificate.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("You’ll Lose") {
                if isSideKick {
                    warningRow("Saved sign-ins", "Apple Accounts, GitHub tokens and imported certificates are stored in the Keychain of your current team. You’ll need to add them again.", "key")
                    warningRow("Private Keychain", "The new copy’s Keychain is shared with every app signed by this certificate, so those apps could read SideKick’s sign-ins.", "lock.open")
                    warningRow("App offloading and restore", "The backup helper needs SideKick’s shared App Group, which this profile doesn’t include.", "arrow.down.app")
                    warningRow("LiveContainer app list", "SideKick can’t read LiveContainer’s shared storage without App Groups.", "square.stack.3d.up")
                    warningRow("Refreshing Apple-signed apps", "After signing in again, SideKick may need a new Apple certificate, which can stop apps signed with the old one from opening.", "arrow.clockwise")
                } else {
                    warningRow("The app’s saved logins", "Its Keychain data belongs to your current team, so the app may sign you out.", "key")
                }

            }

            if isSideKick {
                Section {
                    Text("Recommended: keep SideKick on your Apple certificate and use imported certificates for other apps.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    destination()
                } label: {
                    Text("Re-sign Anyway")
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Before You Re-sign")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func warningRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .padding(.vertical, 2)
    }
}
