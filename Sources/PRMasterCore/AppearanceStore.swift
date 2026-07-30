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
