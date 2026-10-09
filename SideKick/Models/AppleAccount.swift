import Foundation

struct AppleAccount: Identifiable, Hashable, Sendable {
    let id: UUID
    var email: String
    var label: String
    var isPrimary: Bool
    var appsInUse: Int
    var appLimit: Int

    var initials: String {
        email.split(separator: "@").first.map { String($0.prefix(2)).uppercased() } ?? "ID"
    }
}
