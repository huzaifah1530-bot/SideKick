import SwiftUI

struct AccountsView: View {
    @State var viewModel: HomeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section { ForEach(viewModel.accounts) { account in accountRow(account) } }
                Section { Button { } label: { Label("Add Apple ID", systemImage: "plus.circle.fill") } } footer: { Text("Credentials are stored securely in Keychain. SideKick never stores your password in app preferences.") }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sideKickCanvas)
            .navigationTitle("Apple IDs")
            .task { await viewModel.load() }
        }
    }

    private func accountRow(_ account: AppleAccount) -> some View {
        HStack(spacing: 14) {
            Text(account.initials).font(.headline).foregroundStyle(.white).frame(width: 48, height: 48).background(.blue.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 4) { Text(account.label).font(.headline); Text(account.email).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            if account.isPrimary { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .padding(.vertical, 5)
    }
}
