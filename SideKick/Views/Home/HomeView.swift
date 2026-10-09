import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @State var viewModel: HomeViewModel
    var onOpenLibrary: () -> Void = {}
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sideload apps with your Apple ID.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)

                    SwiftUI.Button {
                        showingImporter = true
                    } label: {
                        Label(viewModel.isImporting ? "Importing…" : "Import IPA", systemImage: "square.and.arrow.down")
                    }
                    .disabled(viewModel.isImporting)
                    .listRowBackground(Color.clear)
                }

                SwiftUI.Button(action: onOpenLibrary) {
                    Label("Browse Library", systemImage: "square.stack.3d.up")
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("SideKick")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
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
                SwiftUI.Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? viewModel.noticeMessage ?? "")
            }
        }
    }
}
