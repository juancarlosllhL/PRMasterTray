import Observation

/// Whether macOS will start the app at login, as macOS sees it.
///
/// Three states rather than a boolean because the middle one is real and
/// confusing: a registration can exist while macOS still waits for the user to
/// tick it in System Settings, and an app that showed that as "off" would invite
/// the user to click a switch that already did its job.
public enum LoginItemState: Sendable, Equatable {
    /// Nothing registered. Also what an absent or unrecognised registration
    /// reads as, which is what makes the repair in `repairIfNeeded` safe.
    case off
    case on
    /// Registered, but the user has to approve it under System Settings ›
    /// General › Login Items. Also what an item the user has unticked there
    /// reports — the registration survives being switched off.
    case needsApproval
}

/// macOS's login item registry.
///
/// A port because the real one is `SMAppService`, which talks to a system daemon
/// and mutates machine-wide state — untestable, and not something a test run
/// should be writing to. Everything that has to decide anything lives in
/// `LaunchAtLoginStore` on this side of it.
public protocol LoginItemRegistering: Sendable {
    func state() -> LoginItemState
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Observable state behind the "Open at login" toggle.
///
/// Deliberately not shaped like `AppearanceStore`, and this is the one place in
/// the codebase where a setting is not simply persisted and read back: macOS owns
/// this one. The user can tick it in System Settings while the app is running, so
/// a stored boolean would confidently lie. `state` is read from macOS instead,
/// re-read whenever the popover opens, and the stored preference records only
/// that the user *asked* — which is the one thing macOS cannot tell us.
@MainActor
@Observable
public final class LaunchAtLoginStore {

    public private(set) var state: LoginItemState
    /// Set when macOS refused. There is no logging anywhere in this app, so
    /// without this a refusal would be a switch that springs back in silence.
    public private(set) var lastFailure: String?

    private let loginItem: LoginItemRegistering
    private let preferences: PreferenceStoring

    public init(
        loginItem: LoginItemRegistering,
        preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.loginItem = loginItem
        self.preferences = preferences
        self.state = loginItem.state()
    }

    /// What the toggle shows. True while awaiting approval as well as when
    /// enabled: the user has asked and macOS is the one holding it up.
    public var isEnabled: Bool { state != .off }

    public func setEnabled(_ enabled: Bool) {
        preferences.setLaunchAtLoginRequested(enabled)
        do {
            if enabled { try loginItem.register() } else { try loginItem.unregister() }
            lastFailure = nil
        } catch {
            // macOS's own wording, for the same reason a refused merge shows
            // GitHub's: "Operation not permitted" is what the user needs to see,
            // and a paraphrase would only obscure it.
            lastFailure = error.localizedDescription
        }
        // Re-read rather than assumed. Registering can succeed into
        // `needsApproval` rather than `on`, and the status is documented as
        // eventually consistent, so what macOS says now is the best available
        // answer and what it was asked for is not an answer at all.
        state = loginItem.state()
    }

    public func refresh() {
        state = loginItem.state()
    }

    public func openSystemSettings() {
        loginItem.openSystemSettings()
    }

    /// Puts back a registration the self-updater lost when it replaced the bundle
    /// underneath it.
    ///
    /// The `off` guard is the whole design, not a shortcut. A user who unticks the
    /// app in System Settings leaves the state `needsApproval`, because the
    /// registration outlives being switched off — so this cannot argue with
    /// somebody who has just said no. Only a registration that has actually
    /// vanished reads as `off`, and after an in-place bundle swap that is exactly
    /// what has happened.
    ///
    /// Guarded rather than fired blind for a second reason: this app is ad-hoc
    /// signed, and an ad-hoc signature carries no stable identity across builds.
    /// Apps that re-register unconditionally on every launch have been reported
    /// accumulating duplicate login items nobody can delete.
    public func repairIfNeeded() {
        guard preferences.launchAtLoginRequested(), state == .off else { return }
        setEnabled(true)
    }
}
