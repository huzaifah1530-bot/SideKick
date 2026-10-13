# Temporary install files never cleared

## Where and why

`SideKick/Services/SideKickStorageCleanup.swift` accepted staging directories only when their children were named `App.app`, `App.ipa`, or `.sidekick-disposable`. Actual staging adds `.sidekick-process` and can retain the original app bundle name. Consequently the operation-end classifier refused to mark these folders complete; both Clear and automatic maintenance protected them indefinitely. Interrupted folders from earlier launches were also excluded, and older SideStore staging folders used a different naming format.

## Fix

The shared Foundation classifier recognizes exact UUID-based SideKick staging names with validated process/completion markers, and legacy globally unique staging names with only recognized install contents. It accepts original bundle names and interrupted modern staging directories. Unknown files, backups, arbitrary folder names, and symbolic links remain excluded. Clear can remove recognized stages while existing operation/download guards prevent deletion during active work. Automatic maintenance removes modern leftovers at idle and allows a 24-hour recovery window for unmarked legacy folders. Retained signing sources and exported IPAs keep their existing protections. Recognized stages use a readable title instead of repeating a long UUID.

## Regression coverage

Portable storage tests cover the photographed legacy format, original app bundle names, process markers, interrupted extraction, completion markers surviving relaunch, missing/invalid ownership, unknown recovery files, backup directories, direct-child boundaries, and symbolic links. Device storage UI still requires an installed iOS build to verify against the user's existing files.
