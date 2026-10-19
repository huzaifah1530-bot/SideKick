import SwiftUI

/// Unregisters a page when SwiftUI destroys it (popped or its tab rebuilt), not when another
/// page is pushed over it. `onDisappear` also fires on push, which used to drop the guard
/// while a child page (like choosing the installed build) was editing this page's draft.
@MainActor private final class GuardLifetime {
    let owner = UUID()
    deinit {
        let owner = owner
        Task { @MainActor in UnsavedSettingsCoordinator.shared.unregister(owner: owner) }
    }
}

@MainActor private struct UnsavedSettingsGuard: ViewModifier {
    let isDirty: Bool
    let save: () async -> Bool
    let discard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = UnsavedSettingsCoordinator.shared
    @State private var lifetime = GuardLifetime()

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty || coordinator.isSaving)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .topBarLeading) {
                        SwiftUI.Button {
                            coordinator.requestNavigation(from: lifetime.owner) { dismiss() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .disabled(coordinator.isSaving)
                    }
                }
            }
            .interactiveDismissDisabled(isDirty || coordinator.isSaving)
            .onAppear { register() }
            .onChange(of: isDirty) { _, _ in register() }
    }

    private func register() {
        coordinator.register(owner: lifetime.owner, isDirty: isDirty, save: save, discard: discard)
        // Make sure re-tapping the current tab asks first while this page has edits.
        if isDirty { TabReselectGuard.installInAllWindows() }
    }
}

extension View {
    @MainActor func guardUnsavedSettings(isDirty: Bool, save: @escaping () async -> Bool, discard: @escaping () -> Void) -> some View {
        modifier(UnsavedSettingsGuard(isDirty: isDirty, save: save, discard: discard))
    }
}
