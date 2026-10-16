# Transfer helper App Group request — 16 October 2026

The device failed at the Files export helper's App Group preflight. The original
app was already temporarily replaced, and no export completed. Recover Original
App Binary reinstalls that app; it does not import files or repair a partially
completed restore. Do not delete the native app in response to this error.

The canonical workflow disables Xcode signing, then packages SideBackup.ipa
without preserving its entitlement requests. SideSign's AppBundleSigner starts
from the provisioning profile but removes nonmandatory entitlement keys absent
from the input executable. Consequently, requesting the target groups through
StageBackupAppOperation is insufficient: the unsigned helper lacks the App Group
key the signer tests. Upstream SideStore's Makefile explicitly runs
fakesign-sidebackup to retain this request. The screenshots fit this deterministic
packaging defect, although actual device permissions still need verification.

Before signing/packaging either host variant, package-transfer-helper.py extracts
the embedded IPA with Apple's ditto, ad-hoc signs the helper with an App Group
request, reads the signature back and requires the expected request. It then
repackages the Payload and replaces the original archive only after success.
The placeholder group is a request marker only: SideSign uses the target app's
provisioned group values when signing on device. This grants no container access
by itself and changes neither the source app's groups nor general signing policy.

Portable tests cover workflow ordering for both variants, preserved resources,
successful repackaging, missing signed requests, signing failure, and retention of
the original IPA on failure. A macOS-only test packages a real Mach-O fixture and
checks its embedded request using codesign. Windows cannot run that Apple-tool
test or the iOS product build. No workflow run/status/log was inspected and no
release was published. Device validation remains: install the next built IPA,
recover Spotify's original binary if needed, then repeat Files export and verify
the guest before considering offload. The separate restore/interruption issues
identified during review are not addressed by this packaging fix.

The user reported the first build failure. Inspection of that failed run showed
all 78 Swift core tests passed; the macOS signing fixture then failed before
signing because shutil.copy2 attempted to reproduce restricted system-binary
flags (PermissionError from chflags). Copy only the binary bytes and explicitly
set executable permissions instead. This preserves the actual signing test and
its entitlement assertions; it does not skip or weaken them. The iOS build and
packaging steps had not run. No subsequent build is monitored.
