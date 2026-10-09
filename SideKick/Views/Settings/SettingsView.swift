import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @State private var isChoosingPairingFile = false
    @State private var pairingStatus: String?
    @State private var isShowingPairingStatus = false

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link(destination: URL(string: "https://github.com/huzaifah1530-bot/SideKick")!) {
                        Label("SideKick on GitHub", systemImage: "arrow.up.right")
                    }
                }

                Section("Device pairing") {
                    LabeledContent("Pairing file", value: PairingFileManager.shared.hasPairingFile() ? "Added" : "Not set up")
                    Button("Import pairing file…") { isChoosingPairingFile = true }
                    Link("How to get a pairing file", destination: AppConstants.URLs.pairingDocumentation)
                    Text("Create the file using a computer you’ve paired with this iPhone, then import it here. You don’t need the SideStore app. Without pairing, SideKick can’t install or refresh apps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("SideKick uses open-source signing components. Their notices and licenses are available in the project source.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Open Source")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $isChoosingPairingFile,
                allowedContentTypes: PairingFileManager.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                Task { await importPairingFile(result) }
            }
            .alert("Device pairing", isPresented: $isShowingPairingStatus) {
                Button("OK", role: .cancel) { pairingStatus = nil }
            } message: {
                Text(pairingStatus ?? "")
            }
        }
    }

    @MainActor
    private func importPairingFile(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            try PairingFileManager.shared.importPairingFile(from: url)
            guard let pairingContent = PairingFileManager.shared.fetchPairingFile() else {
                throw PairingSetupError.unreadableFile
            }
            try await AppBootManager.shared.startMinimuxer(pairingFile: pairingContent)
            pairingStatus = "This iPhone is paired and SideKick can reach it. You can now try installing or refreshing an app."
        } catch {
            pairingStatus = "SideKick couldn’t use that pairing file. Make sure it was created for this iPhone and try again.\n\n\(error.localizedDescription)"
        }
        isShowingPairingStatus = true
    }
}

private enum PairingSetupError: LocalizedError {
    case unreadableFile
    var errorDescription: String? { "The pairing file was imported but could not be read." }
}
