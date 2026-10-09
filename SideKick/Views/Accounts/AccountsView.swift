import SwiftUI

struct AccountsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Apple ID signing isn’t connected", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Your Apple ID is not stored by SideKick. Account sign-in and certificate setup will arrive with the signing engine.")
            }
            .navigationTitle("Apple IDs")
        }
    }
}
