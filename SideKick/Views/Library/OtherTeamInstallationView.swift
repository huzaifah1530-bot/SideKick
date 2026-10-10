import SwiftUI
import UniformTypeIdentifiers

struct OtherTeamSourceView: View {
    let app: InstalledAppSummary
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    @Environment(AppEnvironment.self) private var environment
    @State private var source: ImportedIPA?
    @State private var selectingIPA = false
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                Text("\(account.email) belongs to a different signing team. Refresh cannot change the current installation’s team. Select a source IPA to install a separate copy.")
                if app.bundleIdentifier == Bundle.main.bundleIdentifier || app.resignedBundleIdentifier == Bundle.main.bundleIdentifier {
                    Text("A separate SideKick installation has its own database and protected credentials. Add your accounts there again; do not delete this copy before checking the new one.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let source {
                NavigationLink {
                    SeparateInstallReviewView(source: source, account: account, accountStore: accountStore, originalName: app.name)
                } label: { Label("Review Separate Installation", systemImage: "square.on.square") }
            }
            SwiftUI.Button { selectingIPA = true } label: { Label("Choose Original IPA", systemImage: "folder") }.disabled(loading)
            if loading { ProgressView("Reading IPA…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Install with Another Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                source = try await environment.ipaImportStore.importedApps().first {
                    app.updateMatchingBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
                }
            } catch { self.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $selectingIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
            Task {
                loading = true
                defer { loading = false }
                do {
                    let candidate = try await environment.ipaImportStore.prepareIPA(from: result.get())
                    guard app.updateMatchingBundleIdentifiers.contains(candidate.bundleIdentifier.lowercased()) else {
                        throw IPAImportError.bundleIdentifierMismatch(app.bundleIdentifier, candidate.bundleIdentifier)
                    }
                    source = candidate
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct SeparateInstallReviewView: View {
    let source: ImportedIPA
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let originalName: String
    @Environment(AppEnvironment.self) private var environment

    private var standaloneSource: ImportedIPA {
        var value = source
        value.githubImportConfiguration = nil
        value.githubUpdateKey = nil
        value.githubRepositoryURL = nil
        value.isQueuedForUpdate = false
        value.queuedForInstalledAppID = nil
        return value
    }

    var body: some View {
        List {
            Section {
                LabeledContent("App", value: originalName)
                LabeledContent("Version", value: source.version)
                LabeledContent("Account", value: account.email)
                LabeledContent("Team", value: account.teamName)
                Text("This installs using a different signing team. App data, Keychain credentials, and App Group access may not transfer. Keep your existing installation until you have verified the new copy.").foregroundStyle(.secondary)
                Text("The signing engine normally appends the selected team to the bundle ID. If you customize the bundle ID, choose a distinct ID so you keep the original installation.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Separate Installation") }
            NavigationLink {
                InstallConsoleView(app: standaloneSource, account: account, accountStore: accountStore,
                    ipaStore: environment.ipaImportStore, isUpdate: false, onInstalled: nil)
            } label: { Label("Install Separate Copy", systemImage: "square.on.square") }
            Section { Text("This action does not mark the original app’s GitHub build installed or remove its queued update. Configure the new copy’s update source after installation.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Review Installation")
        .navigationBarTitleDisplayMode(.inline)
    }
}
