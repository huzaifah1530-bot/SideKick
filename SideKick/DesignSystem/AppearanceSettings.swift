import SwiftUI
import UIKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User appearance choices. Views read the accent through `Color.sideKickAccent`; because this
/// type is `@Observable`, every view that uses the accent redraws when it changes.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    private enum Key {
        static let mode = "sidekick.appearance.mode"
        static let accent = "sidekick.appearance.accent"
    }

    var mode: AppearanceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode); applyToWindows() }
    }

    /// `nil` means the built-in SideKick Teal, which adapts between light and dark mode.
    var customAccent: RGBColor? {
        didSet {
            if let customAccent { UserDefaults.standard.set(customAccent.hex, forKey: Key.accent) }
            else { UserDefaults.standard.removeObject(forKey: Key.accent) }
            applyToWindows()
            AppIconController.scheduleUpdate(for: customAccent)
        }
    }

    /// Whether the app icon follows the accent hue.
    var matchesAppIcon: Bool {
        didSet {
            AppIconController.matchesAccent = matchesAppIcon
            AppIconController.scheduleUpdate(for: customAccent)
        }
    }

    var isDefault: Bool { mode == .system && customAccent == nil && matchesAppIcon }

    private init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Key.mode) ?? "") ?? .system
        customAccent = UserDefaults.standard.string(forKey: Key.accent).flatMap(RGBColor.init(hex:))
        matchesAppIcon = AppIconController.matchesAccent
    }

    func restoreDefaults() {
        mode = .system
        customAccent = nil
        if !matchesAppIcon { matchesAppIcon = true }
    }

    var accent: Color {
        customAccent.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color("SideKickAccent")
    }

    var accentUIColor: UIColor {
        customAccent.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            ?? UIColor(named: "SideKickAccent") ?? .systemTeal
    }

    /// Text on a solid accent fill: whichever of white or near-black reads better.
    var onAccent: Color {
        guard let customAccent else { return Color("SideKickOnAccent") }
        return customAccent.prefersDarkText ? Color(red: 0.07, green: 0.07, blue: 0.08) : .white
    }

    var accentTint: Color {
        customAccent == nil ? Color("SideKickAccentTint") : accent.opacity(0.18)
    }

    /// UIKit alerts, menus and share sheets read the window, not SwiftUI.
    func applyToWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = accentUIColor
                window.overrideUserInterfaceStyle = mode.interfaceStyle
            }
        }
    }
}

struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 0xFF) / 255,
                  green: Double((number >> 8) & 0xFF) / 255,
                  blue: Double(number & 0xFF) / 255)
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// WCAG relative luminance; dark text wins when it gives more contrast than white.
    var prefersDarkText: Bool {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        return (1.05 / (luminance + 0.05)) < ((luminance + 0.05) / 0.05)
    }
}

struct AppearanceSettingsView: View {
    @Bindable private var settings = AppearanceSettings.shared

    private var accentBinding: Binding<Color> {
        Binding(
            get: { settings.accent },
            set: { settings.customAccent = RGBColor($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Mode")
            }

            Section {
                ColorPicker("Accent Colour", selection: accentBinding, supportsOpacity: false)
                HStack(spacing: Spacing.s) {
                    Text("Preview")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Button")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.onAccent)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                        .background(settings.accent, in: Capsule())
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(settings.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preview of the accent colour")
            } header: {
                Text("Accent")
            } footer: {
                Text("Used for buttons, links, selection and the tab bar.")
            }

            Section {
                Toggle(isOn: $settings.matchesAppIcon) {
                    HStack(spacing: Spacing.s) {
                        if let preview = AppIconController.previewImage(for: settings.customAccent) {
                            Image(uiImage: preview)
                                .resizable()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                        }
                        Text("Match App Icon to Accent")
                    }
                }
            } header: {
                Text("App Icon")
            } footer: {
                Text(AppIconController.liveContainerBundle == nil
                     ? "The icon changes to the nearest matching colour. iOS confirms each change."
                     : "SideKick is running in LiveContainer. Its icon there updates the next time LiveContainer reloads its app list.")
            }

            Section {
                SwiftUI.Button("Restore Defaults") { settings.restoreDefaults() }
                    .disabled(settings.isDefault)
            } footer: {
                Text("Only resets appearance: System mode, the SideKick Teal accent and the original app icon. Your apps, accounts and other settings aren’t changed.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
