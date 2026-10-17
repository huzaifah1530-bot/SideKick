import SwiftUI
import UIKit

/// The shared iCloud shortcut runs: Connect LocalDevVPN → Wait 1 second → Refresh SideKick Apps →
/// Disconnect LocalDevVPN. SideKick is re-signed per user, so its bundle ID differs from the one
/// the shortcut was made with and the SideKick step always arrives as "not found". These views
/// expect that and walk the user through swapping in this install's own action.
enum RefreshShortcut {
    static let downloadURL = URL(string: "https://www.icloud.com/shortcuts/2af57f665d434568a589f1e9b7d7f4d1")!
    static let shortcutsURL = URL(string: "shortcuts://")!
    /// Name of the downloaded shortcut, used to run it for the test.
    static let name = "Refresh SideKick Apps"
    static var runURL: URL? {
        var components = URLComponents(string: "shortcuts://run-shortcut")
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        return components?.url
    }
    /// Written by RefreshManagedAppsIntent every time it runs.
    static let lastAttemptKey = "sidekick.automation.last-attempt"
}

// MARK: - Repair guide

struct ShortcutRepairGuideView: View {
    var body: some View {
        List {
            Section {
                Text("After you add the shortcut, its SideKick step shows as not found. That’s expected: your copy of SideKick is signed differently from the one that made the shortcut. Replace that one step and the rest keeps working.")
                    .font(.subheadline)
            }

            Section {
                ShortcutMockCard(isRepaired: false)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.s, bottom: Spacing.s, trailing: Spacing.s))
            } header: {
                Text("When You Open It")
            }

            Section {
                ShortcutMockCard(isRepaired: true)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.s, bottom: Spacing.s, trailing: Spacing.s))
            } header: {
                Text("After the Fix")
            }

            Section {
                Label("Open the shortcut in Shortcuts and find the “Refresh SideKick Apps” step.", systemImage: "1.circle")
                Label("Tap ⓧ on that step to delete it.", systemImage: "2.circle")
                Label("Tap Search at the bottom, type “Refresh SideKick Apps” and choose SideKick’s action.", systemImage: "3.circle")
                Label("Drag it between “Wait” and “Disconnect”, then tap Done (or ‹ Back) to save.", systemImage: "4.circle")
            } header: {
                Text("Fix the SideKick Step")
            }

            Section {
                Link(destination: RefreshShortcut.shortcutsURL) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
                .fullWidthListSeparators()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Fix the SideKick Step")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A SwiftUI drawing of the shortcut's four actions, styled after the Shortcuts editor.
struct ShortcutMockCard: View {
    let isRepaired: Bool

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Text(RefreshShortcut.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.bottom, Spacing.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Shortcut: \(RefreshShortcut.name). \(isRepaired ? "Repaired" : "As downloaded")")

            ShortcutMockRow(symbol: "network.badge.shield.half.filled", tint: .blue,
                            parts: [.token("Connect"), .text("to"), .token("LocalDevVPN")],
                            accessibility: "Connect to LocalDevVPN. Works.")
            ShortcutMockRow(symbol: "hourglass", tint: .gray,
                            parts: [.text("Wait"), .token("1 second")],
                            accessibility: "Wait 1 second. Works.")
            if isRepaired {
                ShortcutMockRow(symbol: "bolt.fill", tint: .teal,
                                parts: [.text("Refresh SideKick Apps")],
                                accessibility: "Refresh SideKick Apps. Fixed: uses this copy of SideKick.")
            } else {
                ShortcutMockRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                parts: [.text("Refresh SideKick Apps")],
                                isBroken: true,
                                accessibility: "Refresh SideKick Apps. Broken: app not found. Replace this step.")
            }
            ShortcutMockRow(symbol: "network.badge.shield.half.filled", tint: .blue,
                            parts: [.token("Disconnect"), .text("from"), .token("LocalDevVPN")],
                            accessibility: "Disconnect from LocalDevVPN. Works.")
        }
        .padding(Spacing.s)
        .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ShortcutMockRow: View {
    enum Part: Hashable { case text(String), token(String) }
    let symbol: String
    let tint: Color
    let parts: [Part]
    var isBroken = false
    let accessibility: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isBroken ? Color.orange : Color.white)
                .frame(width: 22, height: 22)
                .background(isBroken ? Color.orange.opacity(0.18) : tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(parts, id: \.self) { part in
                        switch part {
                        case .text(let value):
                            Text(value)
                                .foregroundStyle(isBroken ? Color.secondary : Color.primary)
                                .strikethrough(isBroken, color: .secondary)
                        case .token(let value):
                            Text(value)
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .font(.subheadline)
                if isBroken {
                    Text("App not found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
                .font(.subheadline)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isBroken {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Test

/// Runs the shortcut and confirms SideKick's action actually executed: the intent stamps
/// `lastAttemptKey`, so a newer stamp after returning means the repaired step works.
struct ShortcutTestPanel: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var testStartedAt: Date?
    @State private var result: Result?

    enum Result: Equatable { case passed(Date), notYet }

    var body: some View {
        Group {
            switch result {
            case .passed(let date)?:
                Label("Shortcut works · ran \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notYet?:
                Label("SideKick’s step didn’t run yet. Check that you replaced it, then test again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            SwiftUI.Button {
                guard let url = RefreshShortcut.runURL else { return }
                testStartedAt = .now
                result = nil
                openURL(url)
            } label: {
                Label(result == nil ? "Run Shortcut to Test" : "Test Again", systemImage: "play.circle")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let testStartedAt else { return }
            // Give Shortcuts a moment to hand control back after the final step.
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let last = UserDefaults.standard.object(forKey: RefreshShortcut.lastAttemptKey) as? Date, last >= testStartedAt {
                    result = .passed(last)
                } else {
                    result = .notYet
                }
            }
        }
    }
}
