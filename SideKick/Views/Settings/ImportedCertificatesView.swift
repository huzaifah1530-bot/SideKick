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

    private static let certificateTypes: [UTType] = [
        UTType(filenameExtension: "p12"),
        UTType(filenameExtension: "pfx"),
        UTType("com.rsa.pkcs-12")
    ].compactMap { $0 }

    var body: some View {
        List {
            if store.certificates.isEmpty {
                ContentUnavailableView {
                    Label("No Imported Certificates", systemImage: "checkmark.seal")
                } description: {
                    Text("Import a .p12 file that includes its private key to sign apps with your own certificate.")
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
                    Text("Choose which Apple Account uses a certificate from that account’s page. Other accounts keep their Apple certificate.")
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
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.certificateTypes) { result in
            switch result {
            case .success(let url): importCertificate(from: url, password: nil)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert(passwordWasIncorrect ? "Incorrect Password" : "Certificate Password", isPresented: $isAskingForPassword) {
            SecureField("Password", text: $password)
                .textContentType(.password)
            SwiftUI.Button("Cancel", role: .cancel) { resetPasswordPrompt() }
            SwiftUI.Button("Import") {
                guard let url = pendingURL else { return }
                importCertificate(from: url, password: password)
            }
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
        guard let recordToDelete, !store.assignedAccountKeys(for: recordToDelete).isEmpty else {
            return "It’s removed from this iPhone. Installed apps keep working until they expire."
        }
        return "Accounts using it go back to their Apple certificate the next time they sign."
    }

    private func importCertificate(from url: URL, password: String?) {
        do {
            try store.importCertificate(from: url, password: password)
            resetPasswordPrompt()
        } catch ImportedCertificateError.passwordRequired {
            pendingURL = url
            passwordWasIncorrect = false
            self.password = ""
            isAskingForPassword = true
        } catch ImportedCertificateError.incorrectPassword {
            pendingURL = url
            passwordWasIncorrect = true
            self.password = ""
            isAskingForPassword = true
        } catch {
            resetPasswordPrompt()
            errorMessage = error.localizedDescription
        }
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

private struct ImportedCertificateRow: View {
    let record: ImportedCertificateRecord
    let usageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if record.isExpired() {
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
        let expiry = "\(record.isExpired() ? "Expired" : "Expires") \(record.expiryDate.formatted(date: .abbreviated, time: .omitted))"
        switch usageCount {
        case 0: return expiry
        case 1: return "\(expiry) · 1 account"
        default: return "\(expiry) · \(usageCount) accounts"
        }
    }
}

private struct ImportedCertificateDetailView: View {
    let record: ImportedCertificateRecord
    let accountStore: SigningAccountStore
    @State private var store = ImportedCertificateStore.shared
    @State private var isConfirmingDeletion = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var usingAccounts: [SigningAccountSummary] {
        let keys = Set(store.assignedAccountKeys(for: record))
        return accountStore.accounts.filter {
            keys.contains(ImportedCertificateCatalog.accountKey(
                accountIdentifier: $0.accountIdentifier,
                teamIdentifier: $0.teamIdentifier
            ))
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: record.name)
                LabeledContent("Status") {
                    Text(record.isExpired() ? "Expired" : "Valid")
                        .foregroundStyle(record.isExpired() ? .red : .secondary)
                }
                LabeledContent("Issued", value: record.issueDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Expires", value: record.expiryDate.formatted(date: .abbreviated, time: .omitted))
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
                if usingAccounts.isEmpty {
                    Text("No accounts")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usingAccounts) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                            if !account.teamName.isEmpty {
                                Text(account.teamName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Used By")
            } footer: {
                Text("To use this certificate, open an account in Accounts and choose Signing Certificate.")
            }

            Section {
                SwiftUI.Button("Delete Certificate", role: .destructive) { isConfirmingDeletion = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
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
            Text(usingAccounts.isEmpty
                 ? "It’s removed from this iPhone. Installed apps keep working until they expire."
                 : "Accounts using it go back to their Apple certificate the next time they sign.")
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

/// Account → Signing Certificate. Picks Apple's certificate or an imported one.
struct SigningCertificatePickerView: View {
    let account: SigningAccountSummary
    @State private var store = ImportedCertificateStore.shared
    @State private var errorMessage: String?

    private var selectedSerial: String? {
        store.assignedRecord(accountIdentifier: account.accountIdentifier, teamIdentifier: account.teamIdentifier)?.serialNumber
    }

    var body: some View {
        List {
            Section {
                choiceRow(title: "Apple Certificate", subtitle: "Created and renewed by Apple for this account", isSelected: selectedSerial == nil) {
                    select(nil)
                }
            }

            Section {
                if store.certificates.isEmpty {
                    Text("No imported certificates")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.certificates) { record in
                        choiceRow(
                            title: record.name,
                            subtitle: "\(record.isExpired() ? "Expired" : "Expires") \(record.expiryDate.formatted(date: .abbreviated, time: .omitted))",
                            isSelected: selectedSerial?.caseInsensitiveCompare(record.serialNumber) == .orderedSame
                        ) {
                            select(record)
                        }
                        .disabled(record.isExpired())
                    }
                }
                NavigationLink { ImportedCertificatesView() } label: {
                    Text("Manage Certificates")
                }
            } header: {
                Text("Imported")
            } footer: {
                Text("SideKick won’t create or revoke Apple certificates while an imported one is selected. Apps signed with it stop opening if the certificate is revoked.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Signing Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reload() }
        .alert("Signing Certificate", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func choiceRow(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ record: ImportedCertificateRecord?) {
        do { try store.assign(record, to: account) } catch { errorMessage = error.localizedDescription }
    }
}
