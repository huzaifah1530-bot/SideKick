import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    capabilityCard
                    librarySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .background(Color.sideKickCanvas)
            .navigationTitle("SideKick")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.sideKickBlue)
                    .accessibilityLabel("Import IPA")
                }
            }
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

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("IPA LIBRARY READY · ENGINE INTEGRATION IN PROGRESS", systemImage: "shippingbox.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text("Bring your IPA files into SideKick")
                .font(.title3.weight(.bold))
            Text("Your IPA files are stored in your library. Apple ID sign-in, installation, and refresh are not connected yet. Device pairing and LocalDevVPN setup will also be required before the engine can be used.")
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
