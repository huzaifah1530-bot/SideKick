import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    capabilityCard
                    librarySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
            .background(Color.sideKickCanvas)
            .navigationBarHidden(true)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await viewModel.importIPA(from: url) }
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .task { await viewModel.load() }
            .alert(viewModel.errorMessage == nil ? "Added to library" : "Couldn’t import IPA", isPresented: Binding(
                get: { viewModel.errorMessage != nil || viewModel.noticeMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.noticeMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: { Text(viewModel.errorMessage ?? viewModel.noticeMessage ?? "") }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your sideloading library")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text("SideKick")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-1)
            }
            Spacer()
            Button { showingImporter = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.glassProminent)
            .tint(.sideKickBlue)
            .accessibilityLabel("Import IPA")
        }
    }

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("IMPORT WORKS · SIGNING IN PROGRESS", systemImage: "shippingbox.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text("Bring your IPA files into SideKick")
                .font(.title3.weight(.bold))
            Text("SideKick can now inspect IPA metadata and keep the files in your library. Signing, installing, and refreshing still need the SideStore engine and device pairing.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showingImporter = true } label: {
                Label(viewModel.isImporting ? "Importing…" : "Choose an IPA", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isImporting)
        }
        .padding(20)
        .background(.blue.opacity(0.10), in: .rect(cornerRadius: 24))
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Imported IPAs").font(.title2.weight(.bold))
                Spacer()
                Text("\(viewModel.importedApps.count)").foregroundStyle(.secondary)
            }

            if viewModel.importedApps.isEmpty {
                ContentUnavailableView("No IPAs yet", systemImage: "square.and.arrow.down", description: Text("Choose an IPA file to add it to your library."))
                    .padding(.vertical, 14)
            } else {
                ForEach(viewModel.importedApps) { app in
                    ImportedIPARow(app: app)
                }
            }
        }
    }
}
