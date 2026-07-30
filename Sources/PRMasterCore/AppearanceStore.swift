import Observation

/// Which appearance the app draws in.
///
/// `system` is the default and must stay the default: it is what the app did
/// before this setting existed, and an update that repainted everybody's popover
/// would read as a bug rather than as a feature. Backed by `String` because the
/// raw value is what lands in `UserDefaults` — renaming a case would silently
/// reset every existing install to System.
public enum AppTheme: String, Sendable, Equatable, CaseIterable {
    case system, light, dark
}

/// Observable state behind the appearance settings.
///
/// Beside `PRStore` rather than inside it: that one is pull-request state, it
/// already carries five injected dependencies, and nothing here has anything to
/// do with a pull request. Both properties write straight through on assignment,
/// which is what lets the settings window have no Save button.
@MainActor
@Observable
public final class AppearanceStore {

    /// Light, dark, or whatever the system is doing. Applied by the app layer
    /// through `NSApp.appearance` — this type deliberately knows nothing about
    /// AppKit so it can stay in the testable core.
    public var theme: AppTheme {
        didSet { preferences.setTheme(theme) }
    }

    /// Drops hue in favour of contrast. Not the whole story on its own — see
    /// `resolvedContrast`, which also honours what macOS has been told.
    public var monochromeEnabled: Bool {
        didSet { preferences.setMonochromeEnabled(monochromeEnabled) }
    }

    private let preferences: PreferenceStoring

    public init(preferences: PreferenceStoring = UserDefaultsPreferences()) {
        self.preferences = preferences
        // Read, never written back: a launch that touches nothing must leave the
        // keys absent so the fallbacks keep applying.
        self.theme = preferences.theme()
        self.monochromeEnabled = preferences.monochromeEnabled()
    }

    /// What the palette should actually use, given this switch and what macOS
    /// says. The view passes the two environment values it can see; the store
    /// supplies its own switch.
    public func resolvedContrast(
        systemDifferentiateWithoutColor: Bool,
        systemIncreasedContrast: Bool
    ) -> ContrastMode {
        ContrastMode.resolve(
            monochromeEnabled: monochromeEnabled,
            systemDifferentiateWithoutColor: systemDifferentiateWithoutColor,
            systemIncreasedContrast: systemIncreasedContrast
        )
    }
}

extension ContrastMode {

    /// Combines the app's own monochrome switch with what macOS has already been
    /// told, under System Settings › Accessibility › Display.
    ///
    /// OR'd, never replaced. Somebody who has told macOS they cannot use colour
    /// must not also have to find this app's switch — a local preference being
    /// off is not permission to ignore a system accessibility setting. The
    /// consequence worth knowing: the switch in Settings can read off while the
    /// app is drawing monochrome, which is why the settings footer says so.
    ///
    /// Monochrome outranks increased contrast because it already carries the
    /// highest contrast either appearance can offer, so there is nothing for
    /// `increased` to add.
    static func resolve(
        monochromeEnabled: Bool,
        systemDifferentiateWithoutColor: Bool,
        systemIncreasedContrast: Bool
    ) -> ContrastMode {
        if monochromeEnabled || systemDifferentiateWithoutColor { return .monochrome }
        return systemIncreasedContrast ? .increased : .standard
    }
}
