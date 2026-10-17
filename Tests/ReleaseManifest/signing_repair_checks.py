"""Run the composed production ID and entitlement logic with small Swift fixtures."""
from pathlib import Path
import re
import subprocess


def verify_repairs(checkout: Path, compiler: str) -> None:
    operations = checkout / 'SideStore/Core/Operations/PipelineOperations'
    preparation = (operations / 'PrepareAppExtensionBundleIDsOperation.swift').read_text()
    signing = (operations / 'ResignAppOperation.swift').read_text()
    provisioning = (operations / 'FetchProvisioningProfilesOperation.swift').read_text()
    prepare_body = re.search(r'        self.context.appexBundleIds = nil.*?(?=        self.setProgress\(100\))', preparation, re.S).group(0)
    resolved_id = re.search(r'        let newBundleID = .*', signing).group(0)
    validator = re.search(r'    private func validateExtensionIdentifiers.*?(?=\n    private func prepare\()', signing, re.S).group(0)
    request_method = re.search(r'    private func backupGroup.*?(?=\n    func updateFeatures)', provisioning, re.S).group(0)
    normalization = re.search(r'        if targetAppBundle.isAltStoreApp \{.*?(?=        verboseLog\("\[FetchProvisioningProfiles\] Application groups:)', provisioning, re.S).group(0)
    fixture = '''import Foundation
enum OperationError: Error { case invalidApp(reason: String) }
struct Profile { let bundleIdentifier: String; var teamIdentifier = "TEAM" }
struct ALTTeam { let identifier: String }
struct ALTApplication {
    let bundleIdentifier: String
    var appExtensions: [ALTApplication] = []
    var entitlements: [String: any Sendable] = [:]
    var isAltStoreApp = false
    var isExtension = false
}
enum ALTEntitlement { static let appGroups = GroupKey(); struct GroupKey { let rawValue = "groups" } }
extension ALTApplication {
    init?(fileURL: URL) { self.init(bundleIdentifier: "com.sidekick.app.TEAM") }
    var provisioningProfile: Profile? { Profile(bundleIdentifier: bundleIdentifier) }
}
enum Bundle {
    enum Info { static let activeBundleURL = URL(fileURLWithPath: "/SideKick.app") }
    static let baseAltStoreAppGroupID = "group.com.sidekick.app"
    static var main = Host()
    struct Host { var altstoreAppGroup: String? = "group.com.sidekick.app.TEAM" }
}
class Context {
    let bundleIdentifier = "com.kdt.livecontainer"
    var targetBundleIdentifier = "com.custom.livecontainer"
    var targetAppBundle: ALTApplication?
    var provisioningProfiles: [String: Profile]?
    var useMainProfile = true
    var appexBundleIds: [String: String]?
    var customEntitlementsByBundleID: [String: [String: any Sendable]] = [:]
    var additionalEntitlements: [String: any Sendable] = [:]
}
struct Engine {
    let context: Context
    let team = ALTTeam(identifier: "TEAM")
    func verboseLog(_ message: String) {}
    func normalize(_ targetAppBundle: ALTApplication, _ groups: [String]) -> [String] {
        var applicationGroups = groups
        NORMALIZE
        return applicationGroups
    }
    func prepare() throws { PREPARE }
    func resolve(_ appBundle: ALTApplication, identifier: String, profile: Profile) -> String {
        let appexBundleIds = context.appexBundleIds ?? [:]
        RESOLVE
        return newBundleID
    }
    VALIDATOR
    REQUESTS
}
let context = Context()
let engine = Engine(context: context)
let profile = Profile(bundleIdentifier: "com.custom.livecontainer.TEAM")
context.provisioningProfiles = [context.targetBundleIdentifier: profile]
for parent in ["com.kdt.livecontainer", "com.kdt.livecontainer.TEAM"] {
    let ext = ALTApplication(bundleIdentifier: parent + ".ShareExtension", isExtension: true)
    context.targetAppBundle = ALTApplication(bundleIdentifier: parent, appExtensions: [ext])
    try engine.prepare()
    let resolved = engine.resolve(ext, identifier: context.targetBundleIdentifier + ".ShareExtension", profile: profile)
    precondition(resolved == profile.bundleIdentifier + ".ShareExtension")
    try engine.validateExtensionIdentifiers(in: ALTApplication(bundleIdentifier: profile.bundleIdentifier, appExtensions: [ALTApplication(bundleIdentifier: resolved)]))
}
context.useMainProfile = false
try engine.prepare()
precondition(context.appexBundleIds == nil) // no stale mappings in the next pipeline phase
for ids in [[profile.bundleIdentifier], ["another.app.Share"], [profile.bundleIdentifier + ".Share", profile.bundleIdentifier + ".Share"]] {
    do {
        try engine.validateExtensionIdentifiers(in: ALTApplication(bundleIdentifier: profile.bundleIdentifier, appExtensions: ids.map { ALTApplication(bundleIdentifier: $0) }))
        preconditionFailure("An invalid extension structure was accepted")
    } catch OperationError.invalidApp { }
}
let manager = ALTApplication(bundleIdentifier: "com.sidekick.app", entitlements: ["siri": true], isAltStoreApp: true)
let team = ALTTeam(identifier: "TEAM")
let requests = engine.requestedEntitlements(for: manager, team: team)
precondition(requests["groups"] as? [String] == ["group.com.sidekick.app.TEAM"])
precondition(requests["siri"] as? Bool == true)
precondition(engine.normalize(manager, ["group.com.sidekick.app"]) == ["group.com.sidekick.app.TEAM"])
Bundle.main = Bundle.Host(altstoreAppGroup: "group.com.sidekick.app.TEAM.existing")
precondition(engine.normalize(manager, ["group.com.sidekick.app.TEAM.existing"]) == ["group.com.sidekick.app.TEAM.existing"])
Bundle.main = Bundle.Host()
context.customEntitlementsByBundleID[manager.bundleIdentifier] = ["groups": ["group.another"], "custom": true]
let custom = engine.requestedEntitlements(for: manager, team: team)
precondition(custom["groups"] as? [String] == ["group.another", "group.com.sidekick.app.TEAM"])
precondition(custom["custom"] as? Bool == true)
Bundle.main = Bundle.Host(altstoreAppGroup: nil)
precondition(engine.requestedEntitlements(for: manager, team: team)["groups"] as? [String] == ["group.another", "group.com.sidekick.app"])
precondition(engine.requestedEntitlements(for: ALTApplication(bundleIdentifier: "spotify"), team: team)["groups"] == nil)
Bundle.main = Bundle.Host()
precondition(engine.backupGroup(for: ALTTeam(identifier: "OTHERTEAM")) == "group.com.sidekick.app")
'''.replace('PREPARE', prepare_body).replace('RESOLVE', resolved_id).replace('VALIDATOR', validator.replace('private ', '')).replace('REQUESTS', request_method.replace('private ', '')).replace('NORMALIZE', normalization)
    source = checkout / 'SigningRepairFixture.swift'
    source.write_text(fixture)
    binary = checkout / 'signing-repair-fixture'
    subprocess.run([compiler, str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
