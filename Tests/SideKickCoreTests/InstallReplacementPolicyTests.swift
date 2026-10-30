import XCTest
@testable import SideKickCore

final class InstallReplacementPolicyTests: XCTestCase {
    private let installed = [
        InstallReplacementPolicy.InstalledTarget(identifier: "com.app.TEAMONE", name: "Existing Copy"),
        InstallReplacementPolicy.InstalledTarget(identifier: "com.custom", name: "Another App"),
        InstallReplacementPolicy.InstalledTarget(identifier: "com.sidekick.app.TEAM", name: "SideKick")
    ]

    func testSameFinalIdentifierReplacesRegardlessOfWhichCertificateWasChosen() {
        XCTAssertEqual(InstallReplacementPolicy.replacement(finalIdentifier: "com.app.TEAMONE",
            expectedUpdateIdentifier: nil, installed: installed)?.name, "Existing Copy")
        XCTAssertEqual(InstallReplacementPolicy.replacement(finalIdentifier: "COM.APP.teamone",
            expectedUpdateIdentifier: nil, installed: installed)?.name, "Existing Copy")
    }
    func testDifferentTeamSuffixOrUniqueCustomIDDoesNotReplace() {
        for identifier in ["com.app.TEAMTWO", "com.app.clone", ""] {
            XCTAssertNil(InstallReplacementPolicy.replacement(finalIdentifier: identifier,
                expectedUpdateIdentifier: nil, installed: installed))
        }
    }
    func testCustomIDCanReplaceAnUnrelatedAppOrSideKick() {
        XCTAssertEqual(InstallReplacementPolicy.replacement(finalIdentifier: "com.custom",
            expectedUpdateIdentifier: nil, installed: installed)?.name, "Another App")
        XCTAssertEqual(InstallReplacementPolicy.replacement(finalIdentifier: "com.sidekick.app.TEAM",
            expectedUpdateIdentifier: nil, installed: installed)?.name, "SideKick")
    }
    func testQueuedUpdateAuthorizesOnlyTheChosenInstallation() {
        XCTAssertNil(InstallReplacementPolicy.replacement(finalIdentifier: "com.app.TEAMONE",
            expectedUpdateIdentifier: "com.app.TEAMONE", installed: installed))
        XCTAssertEqual(InstallReplacementPolicy.replacement(finalIdentifier: "com.custom",
            expectedUpdateIdentifier: "com.app.TEAMONE", installed: installed)?.name, "Another App")
    }
    func testSeparatePackageRemainsVisibleInImportsEvenWhenItsBundleMatchesAnInstallation() {
        var ipa = ImportedIPA(bundleIdentifier: "com.example.app", name: "App", version: "2",
            fileName: "new.ipa", sourceBookmarkData: nil, sourceURLString: nil,
            importedAt: .now, iconData: nil, isQueuedForUpdate: false, separateInstallationRequested: true)
        XCTAssertTrue(IPAImportIndex.isVisibleInImports(ipa, installedBundleIdentifiers: ["com.example.app"], queuedImportIDs: []))
        ipa.separateInstallationRequested = false
        XCTAssertFalse(IPAImportIndex.isVisibleInImports(ipa, installedBundleIdentifiers: ["com.example.app"], queuedImportIDs: []))
        ipa.isQueuedForUpdate = true
        XCTAssertFalse(IPAImportIndex.isVisibleInImports(ipa, installedBundleIdentifiers: ["com.example.app"], queuedImportIDs: []))
        ipa.queuedForInstalledAppID = "com.example.app.TEAM"
        XCTAssertFalse(IPAImportIndex.isVisibleInImports(ipa, installedBundleIdentifiers: ["com.example.app"], queuedImportIDs: [ipa.id]))
    }
}
