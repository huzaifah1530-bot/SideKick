import Foundation
import Combine

/// Tracks settings pages with unsaved edits so leaving them asks first.
/// A page stays registered while it exists, including while another page is pushed on
/// top of it: edits made from a child page (such as choosing the installed build) must
/// still be caught when the user switches tabs.
@MainActor final class UnsavedSettingsCoordinator: ObservableObject {
    static let shared = UnsavedSettingsCoordinator()
    @Published var isPresented = false
    @Published private(set) var isSaving = false
    private struct Draft {
        let isDirty: Bool
        let save: () async -> Bool
        let discard: () -> Void
    }
    private var drafts: [UUID: Draft] = [:]
    /// Registration order, outermost page first.
    private var order: [UUID] = []
    private var pendingOwners: [UUID] = []
    private var pendingNavigation: (() -> Void)?

    var hasUnsavedChanges: Bool { drafts.values.contains { $0.isDirty } }

    func register(owner: UUID, isDirty: Bool, save: @escaping () async -> Bool, discard: @escaping () -> Void) {
        if drafts[owner] == nil { order.append(owner) }
        drafts[owner] = Draft(isDirty: isDirty, save: save, discard: discard)
    }

    func unregister(owner: UUID) {
        guard drafts.removeValue(forKey: owner) != nil else { return }
        order.removeAll { $0 == owner }
        pendingOwners.removeAll { $0 == owner }
        if pendingOwners.isEmpty {
            pendingNavigation = nil
            isPresented = false
        }
    }

    /// Leaving a whole area (switching or re-tapping a tab): every page with edits asks first.
    func requestNavigation(_ navigate: @escaping () -> Void) {
        request(owners: order, navigate)
    }

    /// Leaving one page with its Back button: only that page's edits matter.
    func requestNavigation(from owner: UUID, _ navigate: @escaping () -> Void) {
        request(owners: [owner], navigate)
    }

    private func request(owners: [UUID], _ navigate: @escaping () -> Void) {
        guard !isSaving else { return }
        let dirty = owners.filter { drafts[$0]?.isDirty == true }
        guard !dirty.isEmpty else { navigate(); return }
        pendingOwners = dirty
        pendingNavigation = navigate
        isPresented = true
    }

    func saveAndLeave() async {
        guard !isSaving, !pendingOwners.isEmpty, let navigate = pendingNavigation else { return }
        isPresented = false
        isSaving = true
        defer { isSaving = false }
        // Innermost page first; a failed save keeps that page and its edits.
        for owner in pendingOwners.reversed() {
            guard let draft = drafts[owner] else { continue }
            guard await draft.save() else { return }
            forget(owner)
        }
        pendingOwners = []
        pendingNavigation = nil
        navigate()
    }

    /// Keeps the user on the edited screen with their draft intact.
    func stay() {
        isPresented = false
        pendingOwners = []
        pendingNavigation = nil
    }

    func discardAndLeave() {
        guard !isSaving, !pendingOwners.isEmpty, let navigate = pendingNavigation else { return }
        isPresented = false
        for owner in pendingOwners.reversed() {
            drafts[owner]?.discard()
            forget(owner)
        }
        pendingOwners = []
        pendingNavigation = nil
        navigate()
    }

    /// The page re-registers when its state next changes.
    private func forget(_ owner: UUID) {
        drafts[owner] = nil
        order.removeAll { $0 == owner }
    }
}
