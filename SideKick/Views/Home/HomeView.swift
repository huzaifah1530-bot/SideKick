import SwiftUI

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    refreshCard
                    appsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
            .background(Color.sideKickCanvas)
            .navigationBarHidden(true)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { _ in }
            .task { await viewModel.load() }
            .alert("Something went wrong", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Good morning")
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
            .accessibilityLabel("Install IPA")
        }
    }

    private var refreshCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("SIGNING STATUS", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("ALL GOOD").font(.caption2.weight(.bold)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Your apps are up to date")
                    .font(.title3.weight(.bold))
                Text("Refresh before your signing window closes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { Task { await viewModel.refreshAll() } } label: {
                Label(viewModel.isRefreshing ? "Refreshing…" : "Refresh all apps", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isRefreshing)
        }
        .padding(20)
        .background(.blue.opacity(0.10), in: .rect(cornerRadius: 24))
        .overlay(alignment: .topTrailing) { Image(systemName: "sparkles").foregroundStyle(.blue.opacity(0.28)).font(.system(size: 62)).offset(x: -14, y: 12) }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Installed apps").font(.title2.weight(.bold)); Spacer(); Text("\(viewModel.apps.count)").foregroundStyle(.secondary) }
            ForEach(viewModel.apps) { app in
                AppRow(app: app) { Task { await viewModel.refresh(app) } }
            }
        }
    }
}

struct AppRow: View {
    let app: SideloadedApp
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIconView(app: app)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.headline)
                Text("v\(app.version)").font(.caption).foregroundStyle(.secondary)
                StatusPill(app: app)
            }
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.glass)
                .disabled(app.status == .refreshing)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 20))
    }
}
