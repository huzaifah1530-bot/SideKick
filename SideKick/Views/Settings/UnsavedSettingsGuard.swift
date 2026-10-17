import SwiftUI

@MainActor private struct UnsavedSettingsGuard: ViewModifier {
    let isDirty: Bool
    let save: () async -> Bool
    let discard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = UnsavedSettingsCoordinator.shared
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty || coordinator.isSaving)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .topBarLeading) {
                        SwiftUI.Button {
                            coordinator.requestNavigation { dismiss() }
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
            .onDisappear { coordinator.unregister(owner: owner) }
    }

    private func register() {
        coordinator.register(owner: owner, isDirty: isDirty, save: save, discard: discard)
        // Make sure re-tapping the current tab asks first while this page has edits.
        if isDirty { TabReselectGuard.installInAllWindows() }
    }
}

extension View {
    @MainActor func guardUnsavedSettings(isDirty: Bool, save: @escaping () async -> Bool, discard: @escaping () -> Void) -> some View {
        modifier(UnsavedSettingsGuard(isDirty: isDirty, save: save, discard: discard))
    }
}
