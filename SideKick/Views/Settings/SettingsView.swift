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
                    Text("This file is a trust record for this iPhone, created once using a computer and iLoader. Import it here. SideStore itself is not required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Install and refresh") {
                    Link(destination: URL(string: "https://apps.apple.com/app/id6755608044")!) {
                        Label("Get LocalDevVPN", systemImage: "arrow.up.right")
                    }
                    Text("The current signing engine needs Wi-Fi and LocalDevVPN connected while installing or refreshing. Apple requires a Network Extension entitlement and tunnel extension; this SideKick build doesn’t have either, so it can’t switch the tunnel on itself. Open LocalDevVPN, tap Connect, then return here.")
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
            UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
            try PairingFileManager.shared.importPairingFile(from: url)
            guard let pairingContent = PairingFileManager.shared.fetchPairingFile() else {
                throw PairingSetupError.unreadableFile
            }
            try await AppBootManager.shared.startMinimuxer(pairingFile: pairingContent)
            do {
                try await ensureMinimuxerReady()
                _ = try await fetchUDID(forceLive: true)
                UserDefaults.standard.set(true, forKey: "sidekick.setup.pairing-verified")
                pairingStatus = "Pairing is set up and SideKick can reach this iPhone. Install and refresh are ready."
            } catch {
                pairingStatus = "Pairing file imported. SideKick couldn’t reach the iPhone yet. Connect to Wi-Fi, open LocalDevVPN, tap Connect, then retry an install or refresh.\n\n\(error.localizedDescription)"
            }
        } catch {
            pairingStatus = "SideKick couldn’t import that pairing file. Make sure it was created for this iPhone and try again.\n\n\(error.localizedDescription)"
        }
        isShowingPairingStatus = true
    }
}

private enum PairingSetupError: LocalizedError {
    case unreadableFile
    var errorDescription: String? { "The pairing file was imported but could not be read." }
}
