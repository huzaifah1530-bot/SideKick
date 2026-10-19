import UIKit

/// Keeps SideKick's app icon in the same hue as the accent colour.
///
/// Installed normally, SideKick switches between the precompiled alternate icons.
/// Running as a LiveContainer guest, the system icon belongs to LiveContainer, so
/// SideKick instead replaces the icon LiveContainer caches inside SideKick's own
/// bundle. LiveContainer shows it the next time it loads its app list.
@MainActor
enum AppIconController {
    private static let matchKey = "sidekick.appearance.matchAppIcon"
    private static var pending: Task<Void, Never>?

    /// On by default; the user can keep the original icon with any accent.
    static var matchesAccent: Bool {
        get { UserDefaults.standard.object(forKey: matchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: matchKey) }
    }

    static func iconName(for accent: RGBColor?) -> String? {
        guard matchesAccent, let accent else { return nil }
        return AppIconVariant.iconName(red: accent.red, green: accent.green, blue: accent.blue)
    }

    /// Preview image for the icon an accent selects.
    static func previewImage(for accent: RGBColor?) -> UIImage? {
        let name = iconName(for: accent).map { $0.replacingOccurrences(of: "AppIcon", with: "AppIconPreview") }
        return UIImage(named: name ?? "AppIconPreview")
    }

    /// Bundle of this guest when LiveContainer runs SideKick. LiveContainer
    /// presents the guest bundle as the main bundle and keeps LCAppInfo.plist in it.
    static var liveContainerBundle: URL? {
        let bundle = Bundle.main.bundleURL
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("LCAppInfo.plist").path) ? bundle : nil
    }

    /// The colour picker reports every drag step and iOS confirms each icon
    /// change with an alert, so apply only once the colour settles.
    static func scheduleUpdate(for accent: RGBColor?) {
        pending?.cancel()
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            await apply(iconName(for: accent))
        }
    }

    static func apply(_ name: String?) async {
        if let bundle = liveContainerBundle {
            updateLiveContainerCache(in: bundle, iconName: name)
            return
        }
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.applicationState == .active,
              application.alternateIconName != name else { return }
        do {
            try await application.setAlternateIconName(name)
        } catch {
            debugLog("[SideKick] Could not change the app icon: \(error.localizedDescription)")
        }
    }

    /// Replaces LiveContainer's cached icon files for this guest. These are cache
    /// files LiveContainer writes itself after signing, not signed resources.
    /// Needs proper testing on device with each LiveContainer release.
    private static func updateLiveContainerCache(in bundle: URL, iconName: String?) {
        let previewName = iconName.map { $0.replacingOccurrences(of: "AppIcon", with: "AppIconPreview") } ?? "AppIconPreview"
        guard let source = UIImage(named: previewName), let data = masked(source).pngData() else { return }
        for file in ["LCAppIconLight.png", "LCAppIconDark.png"] {
            do { try data.write(to: bundle.appendingPathComponent(file), options: .atomic) }
            catch { debugLog("[SideKick] Could not update the LiveContainer icon: \(error.localizedDescription)") }
        }
        // LiveContainer derives its tile colour from the icon; clear it so it is recalculated.
        let infoURL = bundle.appendingPathComponent("LCAppInfo.plist")
        guard let data = try? Data(contentsOf: infoURL),
              var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["cachedColor"] != nil || info["cachedColorDark"] != nil else { return }
        info["cachedColor"] = nil
        info["cachedColorDark"] = nil
        if let updated = try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0) {
            try? updated.write(to: infoURL, options: .atomic)
        }
    }

    /// LiveContainer caches home-screen-style icons that are already masked.
    private static func masked(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size.width * 0.2237).addClip()
            image.draw(in: rect)
        }
    }
}
