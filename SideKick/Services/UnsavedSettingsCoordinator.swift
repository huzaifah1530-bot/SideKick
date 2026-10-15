import Foundation
import Combine

@MainActor final class UnsavedSettingsCoordinator: ObservableObject {
    static let shared = UnsavedSettingsCoordinator()
    @Published var isPresented = false
    @Published private(set) var isSaving = false
    private struct Draft {
        let owner: UUID
        let isDirty: Bool
        let save: () async -> Bool
        let discard: () -> Void
    }
    private var draft: Draft?
    private var pendingNavigation: (() -> Void)?

    func register(owner: UUID, isDirty: Bool, save: @escaping () async -> Bool, discard: @escaping () -> Void) {
        draft = Draft(owner: owner, isDirty: isDirty, save: save, discard: discard)
    }

    func unregister(owner: UUID) {
        guard draft?.owner == owner else { return }
        draft = nil
        pendingNavigation = nil
        isPresented = false
    }

    func requestNavigation(_ navigate: @escaping () -> Void) {
        guard !isSaving else { return }
        guard draft?.isDirty == true else { navigate(); return }
        pendingNavigation = navigate
        isPresented = true
    }

    func saveAndLeave() async {
        guard !isSaving, let draft, let navigate = pendingNavigation else { return }
        isPresented = false
        isSaving = true
        defer { isSaving = false }
        guard await draft.save() else { return }
        self.draft = nil
        pendingNavigation = nil
        navigate()
    }

    func discardAndLeave() {
        guard !isSaving, let draft, let navigate = pendingNavigation else { return }
        isPresented = false
        draft.discard()
        self.draft = nil
        pendingNavigation = nil
        navigate()
    }
}
