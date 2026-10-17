import SwiftUI
import UIKit

// MARK: - App icon

/// One app-icon treatment for the whole app: continuous corners at Apple's icon ratio,
/// a hairline edge so dark icons separate from dark surfaces, and one neutral fallback.
struct SideKickAppIcon: View {
    enum Size {
        case list, featured, hero

        var points: CGFloat {
            switch self {
            case .list: 48
            case .featured: 64
            case .hero: 96
            }
        }
    }

    let data: Data?
    var size: Size = .list
    var systemImage = "app.fill"

    var body: some View {
        let side = size.points
        let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    Image(systemName: systemImage)
                        .resizable()
                        .scaledToFit()
                        .padding(side * 0.26)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

// MARK: - Status badge

/// A short status capsule. Always pairs colour with a symbol and words.
struct StatusBadge: View {
    let title: String
    let systemImage: String
    var tone: StatusTone = .neutral

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tone.color)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tone.color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

// MARK: - Status symbol

/// A hero glyph inside a tinted circle, so the symbol never has to be scaled past its intended size.
struct StatusSymbol: View {
    let systemImage: String
    var tone: StatusTone = .accent
    var isAnimating = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.title.weight(.semibold))
            .foregroundStyle(tone.color)
            .symbolEffect(.pulse, isActive: isAnimating)
            .frame(width: 72, height: 72)
            .background(tone.color.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Action hierarchy

extension View {
    /// The single most important action on a screen. Liquid Glass on iOS 26, filled capsule before.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.sideKickAccent)
                .foregroundStyle(Color.sideKickOnAccent)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.sideKickAccent)
                .foregroundStyle(Color.sideKickOnAccent)
        }
    }

    /// Supporting actions next to or below the primary action.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } else {
            self
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    /// Shows a running multi-app refresh in the Liquid Glass tab bar accessory (iOS 26.2+; 26.1 hides it unreliably),
    /// so progress stays visible after leaving My Apps. Earlier systems keep the in-list status row.
    @ViewBuilder
    func refreshActivityAccessory(_ activity: RefreshActivity?, onTap: @escaping () -> Void) -> some View {
        if #available(iOS 26.2, *) {
            self.tabViewBottomAccessory(isEnabled: activity != nil) {
                if let activity {
                    RefreshActivityAccessory(activity: activity, onTap: onTap)
                }
            }
        } else {
            self
        }
    }

    /// Glass behind floating, non-list content such as a bottom action bar.
    @ViewBuilder
    func floatingBarBackground() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            self.background(.bar)
        }
    }
}

/// Bottom action area for detail and status screens. Content scrolls beneath it.
struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Spacing.s) { content }
            .frame(maxWidth: SideKickLayout.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xs)
            .floatingBarBackground()
    }
}

/// Full-width label used inside primary and secondary buttons.
struct ActionLabel: View {
    let title: String
    var systemImage: String?
    var isWorking = false

    init(_ title: String, systemImage: String? = nil, isWorking: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isWorking = isWorking
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if isWorking {
                ProgressView()
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Alerts

extension View {
    /// One alert pattern for messages that clear when dismissed.
    func messageAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

// MARK: - Account avatar

/// Initial-letter avatar for Apple Accounts, tinted teal so accounts read as SideKick content.
struct AccountAvatar: View {
    let email: String
    var size: CGFloat = 40

    private var initial: String {
        email.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(initial)
            .font(size > 48 ? .title.weight(.semibold) : .headline)
            .foregroundStyle(Color.sideKickAccent)
            .frame(width: size, height: size)
            .background(Color.sideKickAccentTint, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Header

/// Hero header used by detail screens: icon, title, one line of supporting text, optional badge.
struct DetailHeader<Badge: View>: View {
    let iconData: Data?
    let title: String
    let subtitle: String
    @ViewBuilder var badge: Badge

    var body: some View {
        VStack(spacing: Spacing.s) {
            SideKickAppIcon(data: iconData, size: .hero)
            VStack(spacing: Spacing.xxs) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            badge
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xs)
    }
}

extension DetailHeader where Badge == EmptyView {
    init(iconData: Data?, title: String, subtitle: String) {
        self.init(iconData: iconData, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Refresh activity accessory

struct RefreshActivityAccessory: View {
    let activity: RefreshActivity
    let onTap: () -> Void

    var body: some View {
        SwiftUI.Button(action: onTap) {
            HStack(spacing: Spacing.s) {
                ProgressView(value: activity.fraction)
                    .progressViewStyle(.circular)
                    .tint(.sideKickAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(activity.completed) of \(activity.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows My Apps")
    }
}

// MARK: - Floating downloads button

extension View {
    @ViewBuilder
    func floatingGlassCircle() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

/// Downloads that keep running after you leave their page collapse into this button.
/// One download opens its page directly; several open a menu with each one's progress.
struct ActiveDownloadsButton: View {
    @Environment(AppEnvironment.self) private var environment
    let open: (String) -> Void

    private var store: GitHubUpdateDownloadStore { environment.githubUpdateDownloads }
    private var imports: IPAImportDownloadStore { environment.importDownloads }
    /// Update downloads keep their candidate ID; import jobs are prefixed with "import:".
    private var ids: [String] { store.activeJobIDs + imports.activeJobIDs.map { "import:" + $0.uuidString } }

    private func importJob(_ id: String) -> IPAImportDownloadStore.Job? {
        guard id.hasPrefix("import:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) else { return nil }
        return imports.jobs[uuid]
    }

    /// (isDownloading, progress) for either kind of job.
    private func progressInfo(_ id: String) -> (Bool, Double?) {
        if let job = importJob(id) { return (job.state == .downloading, job.progress?.fractionCompleted) }
        if let job = store.jobs[id] { return (job.isDownloading, job.progress) }
        return (false, nil)
    }

    var body: some View {
        if !ids.isEmpty {
            Group {
                if ids.count == 1 {
                    SwiftUI.Button { open(ids[0]) } label: { ring }
                        .accessibilityLabel("\(name(ids[0])), \(status(ids[0]))")
                } else {
                    Menu {
                        ForEach(ids, id: \.self) { id in
                            SwiftUI.Button { open(id) } label: {
                                Text(name(id))
                                Text(status(id))
                            }
                        }
                    } label: { ring }
                    .accessibilityLabel("\(ids.count) downloads")
                }
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var ring: some View {
        let downloading = ids.map(progressInfo).filter(\.0)
        let progress = downloading.isEmpty ? 1 : downloading.map { $0.1 ?? 0 }.reduce(0, +) / Double(downloading.count)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(Color.sideKickAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
            Image(systemName: downloading.isEmpty ? "checkmark" : "arrow.down")
                .font(.headline)
                .foregroundStyle(Color.sideKickAccent)
        }
        .padding(Spacing.s)
        .frame(width: 56, height: 56)
        .floatingGlassCircle()
        .overlay(alignment: .topTrailing) {
            if ids.count > 1 {
                Text("\(ids.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.sideKickOnAccent)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.sideKickAccent, in: Circle())
                    .offset(x: 2, y: -2)
            }
        }
        .contentShape(Circle())
    }

    private func name(_ id: String) -> String {
        if let job = importJob(id) { return job.title }
        guard let candidate = store.candidates[id] else { return "Download" }
        return environment.installedApps.first { $0.id == candidate.bundleIdentifier }?.name
            ?? environment.liveContainerState.apps.first { $0.id == candidate.bundleIdentifier }?.name
            ?? candidate.appName
    }

    private func status(_ id: String) -> String {
        if let job = importJob(id) {
            switch job.state {
            case .downloading:
                guard let fraction = job.progress?.fractionCompleted else { return "Starting…" }
                return "Downloading · \(Int(fraction * 100))%"
            case .needsTarget: return "Choose which app to update"
            case .ready: return "Ready to install"
            case .failed: return "Failed"
            }
        }
        guard let job = store.jobs[id] else { return "" }
        if job.isDownloading {
            guard let progress = job.progress else { return "Starting…" }
            return "Downloading · \(Int(progress * 100))%"
        }
        return "Ready to install"
    }
}
