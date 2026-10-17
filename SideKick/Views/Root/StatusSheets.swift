import SwiftUI

/// Slides up after an update finishes installing: old → new version and, for GitHub releases,
/// the matching release notes.
struct UpdateSuccessSheet: View {
    let record: UpdateSuccessRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    VStack(spacing: Spacing.s) {
                        SideKickAppIcon(data: record.iconData, size: .hero)
                        Text("Successfully Updated")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(record.appName)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: Spacing.xs) {
                            Text(record.oldVersion).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(Color.sideKickAccent)
                                .accessibilityLabel("to")
                            Text(versionLabel).fontWeight(.semibold)
                        }
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }
                    .frame(maxWidth: .infinity)

                    if let notes = record.releaseNotes {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(record.releaseTitle.map { "Release Notes · \($0)" } ?? "Release Notes")
                                .font(.headline)
                            Text(LocalizedStringKey(notes))
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Spacing.m)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(maxWidth: SideKickLayout.readableWidth)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(Color.sideKickCanvas)
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    SwiftUI.Button { dismiss() } label: { ActionLabel("Done") }
                        .primaryActionStyle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SwiftUI.Button("Done") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents(record.releaseNotes == nil ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: record.id)
    }

    private var versionLabel: String {
        record.newBuild.isEmpty || record.newBuild == record.newVersion ? record.newVersion : "\(record.newVersion) (\(record.newBuild))"
    }
}

/// Opens from the "Automatic refresh didn't finish" notification.
struct RefreshFailureSheet: View {
    let report: RefreshFailureReport
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: Spacing.s) {
                        StatusSymbol(systemImage: "exclamationmark.triangle.fill", tone: .warning)
                        Text("Automatic Refresh Didn’t Finish")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(report.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let name = report.soonestAppName {
                            StatusBadge(
                                title: report.soonestDays <= 0 ? "\(name) has expired" : "\(name) expires in \(report.soonestDays) \(report.soonestDays == 1 ? "day" : "days")",
                                systemImage: "clock.badge.exclamationmark",
                                tone: report.soonestDays <= 1 ? .critical : .warning
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
                }
                .listRowBackground(Color.clear)

                Section { Text(report.summary) }

                if !report.items.isEmpty {
                    Section("What Went Wrong") {
                        ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                            let explanation = OperationFailureExplanation(message: item.message)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(item.appName).font(.body.weight(.semibold))
                                Text(explanation.summary).font(.subheadline)
                                if let advice = explanation.advice {
                                    Text(advice).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, Spacing.xxs)
                        }
                    }
                }

                Section {
                    SwiftUI.Button {
                        UIPasteboard.general.string = ([report.summary] + report.items.map { "\($0.appName): \($0.message)" }).joined(separator: "\n")
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Details", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("Your shortcut still finished, so its “turn off VPN” step ran. Open My Apps and tap Refresh All to try again now.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    SwiftUI.Button { dismiss() } label: { ActionLabel("Done") }
                        .primaryActionStyle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SwiftUI.Button("Done") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }
}
