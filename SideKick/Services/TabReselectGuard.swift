import UIKit

/// Tapping the tab you're already on pops that tab to its root inside UIKit, which bypasses
/// SwiftUI and the unsaved-settings guard. This sits in front of SwiftUI's own tab bar delegate,
/// asks first when there are unsaved changes, and forwards everything else unchanged.
@MainActor
final class TabReselectGuard: NSObject, UITabBarControllerDelegate {
    private static var installed: [ObjectIdentifier: TabReselectGuard] = [:]
    private weak var original: UITabBarControllerDelegate?

    private init(original: UITabBarControllerDelegate?) {
        self.original = original
    }

    /// Re-checks every window. Cheap, and covers SwiftUI replacing the delegate later.
    static func installInAllWindows() {
        install(in: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows))
    }

    /// Safe to call repeatedly; installs once per tab bar controller.
    static func install(in windows: [UIWindow]) {
        for window in windows {
            guard let tabs = findTabBarController(window.rootViewController) else { continue }
            if tabs.delegate is TabReselectGuard { continue }
            let guardDelegate = TabReselectGuard(original: tabs.delegate)
            installed[ObjectIdentifier(tabs)] = guardDelegate
            tabs.delegate = guardDelegate
        }
    }

    /// SwiftUI's `Tab {}` API drives UIKit's iOS 18 UITab delegate method, not the older one.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if tab === tabBarController.selectedTab, UnsavedSettingsCoordinator.shared.hasUnsavedChanges {
            let root = tab.viewController
            UnsavedSettingsCoordinator.shared.requestNavigation { [weak root] in
                Self.findNavigationController(root)?.popToRootViewController(animated: true)
            }
            return false
        }
        return original?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === tabBarController.selectedViewController,
           UnsavedSettingsCoordinator.shared.hasUnsavedChanges {
            UnsavedSettingsCoordinator.shared.requestNavigation { [weak viewController] in
                Self.findNavigationController(viewController)?.popToRootViewController(animated: true)
            }
            return false
        }
        return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
    }

    // Forward every other delegate call to SwiftUI's delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    private static func findTabBarController(_ controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = findTabBarController(child) { return found }
        }
        return findTabBarController(controller.presentedViewController)
    }

    private static func findNavigationController(_ controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = findNavigationController(child) { return found }
        }
        return nil
    }
}
