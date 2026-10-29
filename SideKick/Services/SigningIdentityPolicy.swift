import Foundation

enum SigningIdentityPolicy {
    enum IdentityError: LocalizedError {
        case missingIdentity, differentTeam
        var errorDescription: String? {
            switch self {
            case .missingIdentity: "SideKick cannot verify the installed app's signing identity. Import its original IPA before continuing. The saved app has not been changed."
            case .differentTeam: "This certificate belongs to a different signing team than the installed app. Install a separate copy from its IPA instead. The existing app and its data have not been changed."
            }
        }
    }

    static func validateResign(installedTeam: String?, targetTeam: String) throws {
        guard let installedTeam, !installedTeam.isEmpty, !targetTeam.isEmpty else { throw IdentityError.missingIdentity }
        guard installedTeam == targetTeam else { throw IdentityError.differentTeam }
    }
}
