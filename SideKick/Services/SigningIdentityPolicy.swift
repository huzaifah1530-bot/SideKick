import Foundation

enum SigningIdentityPolicy {
    enum IdentityError: LocalizedError {
        case missingIdentity, differentTeam, incompatibleProfile
        var errorDescription: String? {
            switch self {
            case .missingIdentity: "SideKick cannot verify the installed app's signing identity. Import its original IPA before continuing. The saved app has not been changed."
            case .differentTeam: "This certificate belongs to a different signing team than the installed app. Install a separate copy from its IPA instead. The existing app and its data have not been changed."
            case .incompatibleProfile: "This provisioning profile is restricted to another App ID. Import a wildcard profile or a profile made for this app. Reusing another app's signing identity can make playback and system links open the wrong app."
            }
        }
    }

    static func validateResign(installedTeam: String?, targetTeam: String) throws {
        guard let installedTeam, !installedTeam.isEmpty, !targetTeam.isEmpty else { throw IdentityError.missingIdentity }
        guard installedTeam == targetTeam else { throw IdentityError.differentTeam }
    }

    static func validateProfile(_ profileID: String, for bundleID: String) throws {
        let matches = profileID.hasSuffix("*")
            ? bundleID.hasPrefix(String(profileID.dropLast()))
            : profileID == bundleID
        guard !bundleID.isEmpty, !bundleID.contains("*"), matches else { throw IdentityError.incompatibleProfile }
    }
}
