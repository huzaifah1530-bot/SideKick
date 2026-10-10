"""Run after SideKick patches; adds a real target, dependency and embed phase."""
from pathlib import Path
import re
import plistlib
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/SideStore")
project = root / "AltStore.xcodeproj/project.pbxproj"
text = project.read_text(encoding="utf-8")
if "SideKickVPN.appex" in text:
    raise SystemExit("SideKick VPN target is already installed")

def uid(number):
    return f"F2B0B000000000000000{number:04X}"

def append(section, value):
    global text
    marker = f"/* End {section} section */"
    if marker not in text:
        raise RuntimeError(f"Missing Xcode section: {section}")
    text = text.replace(marker, value + "\n" + marker, 1)

def add_to_object_list(identifier, key, value):
    global text
    pattern = rf"(\t\t{identifier}(?: /\*.*?\*/)? = \{{.*?\n\t\t\}};)"
    match = re.search(pattern, text, re.S)
    if not match:
        raise RuntimeError(f"Missing project object: {identifier}")
    block = match.group(1)
    needle = key + " = ("
    if needle not in block:
        raise RuntimeError(f"Missing {key} in {identifier}")
    block = block.replace(needle, needle + "\n\t\t\t\t" + value + ",", 1)
    text = text[:match.start()] + block + text[match.end():]

sources = ["PacketTunnelProvider.swift", "CIDRValidator.swift", "TunnelConstants.swift"]
for index, name in enumerate(sources):
    append("PBXFileReference", f'\t\t{uid(20+index)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
    append("PBXBuildFile", f'\t\t{uid(30+index)} = {{isa = PBXBuildFile; fileRef = {uid(20+index)}; }};')
append("PBXFileReference", f'\t\t{uid(2)} = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = SideKickVPN.appex; sourceTree = BUILT_PRODUCTS_DIR; }};')
append("PBXGroup", f'\t\t{uid(3)} = {{isa = PBXGroup; children = ({", ".join(uid(20+i) for i in range(3))}, ); path = ../../SideKickVPN; sourceTree = "<group>"; }};')
append("PBXSourcesBuildPhase", f'\t\t{uid(4)} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(uid(30+i) for i in range(3))}, ); runOnlyForDeploymentPostprocessing = 0; }};')
append("PBXFrameworksBuildPhase", f'\t\t{uid(5)} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
append("PBXResourcesBuildPhase", f'\t\t{uid(6)} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
append("PBXBuildFile", f'\t\t{uid(7)} = {{isa = PBXBuildFile; fileRef = {uid(2)}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};')
append("PBXCopyFilesBuildPhase", f'\t\t{uid(8)} = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({uid(7)}, ); name = "Embed SideKick VPN"; runOnlyForDeploymentPostprocessing = 0; }};')
append("PBXContainerItemProxy", f'\t\t{uid(9)} = {{isa = PBXContainerItemProxy; containerPortal = BFD247622284B9A500981D42; proxyType = 1; remoteGlobalIDString = {uid(1)}; remoteInfo = SideKickVPN; }};')
append("PBXTargetDependency", f'\t\t{uid(10)} = {{isa = PBXTargetDependency; target = {uid(1)}; targetProxy = {uid(9)}; }};')
append("PBXNativeTarget", f'\t\t{uid(1)} = {{isa = PBXNativeTarget; buildConfigurationList = {uid(11)}; buildPhases = ({uid(4)}, {uid(5)}, {uid(6)}, ); buildRules = (); dependencies = (); name = SideKickVPN; productName = SideKickVPN; productReference = {uid(2)}; productType = "com.apple.product-type.app-extension"; }};')
settings = """APPLICATION_EXTENSION_API_ONLY = YES;
CODE_SIGN_ENTITLEMENTS = ../../SideKickVPN/SideKickVPN.entitlements;
CODE_SIGN_STYLE = Automatic;
GENERATE_INFOPLIST_FILE = NO;
INFOPLIST_FILE = ../../SideKickVPN/Info.plist;
IPHONEOS_DEPLOYMENT_TARGET = 26.0;
LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks", );
PRODUCT_BUNDLE_IDENTIFIER = "$(MAIN_BUNDLE_IDENTIFIER).SideKickVPN";
PRODUCT_NAME = SideKickVPN;
PRODUCT_MODULE_NAME = SideKickVPN;
SKIP_INSTALL = YES;
SWIFT_VERSION = 5.0;
SWIFT_EMIT_LOC_STRINGS = NO;
TARGETED_DEVICE_FAMILY = "1,2";
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
"""
for number, name in [(12,"Debug"),(13,"Release")]:
    append("XCBuildConfiguration", f'\t\t{uid(number)} = {{isa = XCBuildConfiguration; baseConfigurationReferenceAnchor = A8EEC71D2F4B10D900F2436D; baseConfigurationReferenceRelativePath = AltStore.xcconfig; buildSettings = {{ {settings} }}; name = {name}; }};')
# The app and tunnel share AltStore.xcconfig through the synchronized xcconfigs group.
append("XCConfigurationList", f'\t\t{uid(11)} = {{isa = XCConfigurationList; buildConfigurations = ({uid(12)}, {uid(13)}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
add_to_object_list("BFD247692284B9A500981D42", "buildPhases", uid(8))
add_to_object_list("BFD247692284B9A500981D42", "dependencies", uid(10))
add_to_object_list("BFD247622284B9A500981D42", "targets", uid(1))
add_to_object_list("BFD247612284B9A500981D42", "children", uid(3))
add_to_object_list("BFD2476B2284B9A500981D42", "children", uid(2))
project.write_text(text, encoding="utf-8")
for relative in ["AltStore/AltStoreFree.entitlements", "AltStore/Resources/ReleaseEntitlements.plist"]:
    path = root / relative
    value = plistlib.loads(path.read_bytes())
    value["com.apple.developer.networking.networkextension"] = ["packet-tunnel-provider"]
    value["com.apple.developer.networking.vpn.api"] = ["allow-vpn"]
    path.write_bytes(plistlib.dumps(value))
print("Embedded SideKickVPN target with host and extension entitlements")

app_delegate = root / "AltStore/AppDelegate.swift"
source = app_delegate.read_text(encoding="utf-8")
original = "        _ = try? AppManager.shared.backgroundRefresh(installedApps, completionHandler: refreshAppsCompletionHandler)"
replacement = """        Task { @MainActor in
            do {
                let lease = try await LocalVPNService.shared.acquire()
                do {
                    _ = try AppManager.shared.backgroundRefresh(installedApps) { result in
                        Task { @MainActor in
                            LocalVPNService.shared.release(lease)
                            refreshAppsCompletionHandler(result)
                        }
                    }
                } catch {
                    LocalVPNService.shared.release(lease)
                    refreshAppsCompletionHandler(.failure(error))
                }
            } catch {
                refreshAppsCompletionHandler(.failure(error))
            }
        }"""
if source.count(original) != 1:
    raise RuntimeError("Upstream background refresh integration point changed")
app_delegate.write_text(source.replace(original, replacement, 1), encoding="utf-8")

removal_file = root / "SideStore/Core/Operations/PipelineOperations/RemoveAppExtensionsOperation.swift"
source = removal_file.read_text(encoding="utf-8")
original = "        if let preset = UserDefaults.standard.customizeAppExtensions.fixedDecision {"
replacement = """        if (targetAppBundle.bundleIdentifier == StoreApp.altstoreAppID || targetAppBundle.bundleIdentifier.hasPrefix("com.sidekick.app")),
           targetAppBundle.appExtensions.contains(where: { $0.fileURL.lastPathComponent == "SideKickVPN.appex" }) {
            // The local tunnel is required for the next SideKick install/refresh.
            // Give it its own profile even if general extension customizations differ.
            decision = .keepAll(useMainProfile: false)
        } else if let preset = UserDefaults.standard.customizeAppExtensions.fixedDecision {"""
if source.count(original) != 1:
    raise RuntimeError("Upstream extension-removal integration point changed")
source = source.replace(original, replacement, 1)
original_guard = "        // target App Bundle doesn't contain extensions so don't bother"
replacement_guard = """        if (targetAppBundle.bundleIdentifier == StoreApp.altstoreAppID || targetAppBundle.bundleIdentifier.hasPrefix("com.sidekick.app")),
           !targetAppBundle.appExtensions.contains(where: { $0.fileURL.lastPathComponent == "SideKickVPN.appex" }) {
            throw OperationError.invalidParameters("This SideKick source has no built-in VPN extension. Import the complete current SideKick IPA before updating or refreshing it.")
        }

        // target App Bundle doesn't contain extensions so don't bother"""
if source.count(original_guard) != 1:
    raise RuntimeError("Upstream extension validation integration point changed")
removal_file.write_text(source.replace(original_guard, replacement_guard, 1), encoding="utf-8")

build_config = root / "Build.xcconfig"
source = build_config.read_text(encoding="utf-8")
source, count = re.subn(r"^MARKETING_VERSION = .*$", "MARKETING_VERSION = 0.8.0", source, count=1, flags=re.M)
if count != 1:
    raise RuntimeError("Missing app marketing version")
build_config.write_text(source, encoding="utf-8")
