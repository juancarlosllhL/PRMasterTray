import ServiceManagement
import PRMasterCore

/// Registers the app itself as a login item.
///
/// Lives in the app target rather than `PRMasterCore` for the same reason as
/// `AppUpdateInstaller`: every line of it is untestable by construction. It talks
/// to a system daemon and mutates state belonging to the whole login session, so
/// a test run that touched it would be editing the developer's login items. What
/// can be decided was pushed down into `LaunchAtLoginStore`, which is where the
/// three states are actually reasoned about.
///
/// `SMAppService.mainApp` needs no bundled launchd plist and no entitlement —
/// that requirement belongs to `.agent(plistName:)` and `.daemon(plistName:)`.
/// The item appears in System Settings under `CFBundleDisplayName`, so it reads
/// as "PR Master Tray" rather than as a helper nobody recognises.
struct SMAppServiceLoginItem: LoginItemRegistering {

    func state() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .on
        // Registered, but macOS wants the user to tick it. This is also what an
        // item the user has unticked in System Settings reports, which is what
        // lets the store tell that apart from a registration that has actually
        // gone — see `LaunchAtLoginStore.repairIfNeeded`.
        case .requiresApproval:
            return .needsApproval
        case .notRegistered, .notFound:
            return .off
        // `SMAppService.Status` is an imported Objective-C enum, so Swift will
        // not accept an exhaustive switch over it.
        @unknown default:
            return .off
        }
    }

    func register() throws { try SMAppService.mainApp.register() }

    func unregister() throws { try SMAppService.mainApp.unregister() }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
