import SwiftUI
import PRMasterCore

/// The palette a view tree draws from, already resolved for the appearance it is
/// in and the contrast it has been asked for.
///
/// `Equatable` so handing it to the environment does not invalidate the tree on
/// every body evaluation.
struct ResolvedPalette: Equatable {
    let appearance: AppearanceMode
    let contrast: ContrastMode

    /// Glyph and label alike. Verified against WCAG by `PaletteTests`.
    func color(_ tint: ReadinessTint) -> Color {
        Palette.foreground(tint, appearance: appearance, contrast: contrast).color
    }

    /// The band behind a banner. Decorative, so it keeps the vivid wash that AA
    /// would forbid in text — except in monochrome, where hue is the thing being
    /// removed, and a neutral band has to stand in for it.
    func wash(_ tint: ReadinessTint) -> Color {
        contrast == .monochrome
            ? Color.primary.opacity(0.08)
            : color(tint).opacity(0.14)
    }

    /// True when colour is carrying nothing, so the views can lean harder on
    /// weight instead.
    var isMonochrome: Bool { contrast == .monochrome }

    /// Built from what a view can see of its own surroundings.
    ///
    /// `colorScheme` follows the effective `NSAppearance`, so this picks up a
    /// theme override without being told one happened.
    static func resolve(
        colorScheme: ColorScheme,
        systemContrast: ColorSchemeContrast,
        differentiateWithoutColor: Bool,
        monochromeEnabled: Bool
    ) -> ResolvedPalette {
        ResolvedPalette(
            appearance: colorScheme == .dark ? .dark : .light,
            contrast: ContrastMode.resolve(
                monochromeEnabled: monochromeEnabled,
                systemDifferentiateWithoutColor: differentiateWithoutColor,
                systemIncreasedContrast: systemContrast == .increased
            )
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    /// Only reached by a view rendered outside `resolvedPalette(...)` — a preview,
    /// or a root somebody forgot to wrap. Light/standard rather than dark,
    /// because dark values on a light background is the unreadable direction.
    static let defaultValue = ResolvedPalette(appearance: .light, contrast: .standard)
}

extension EnvironmentValues {
    var palette: ResolvedPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Reads the three environment values a palette is derived from, so a view that
/// needs one does not have to declare all three itself.
///
/// Deliberately *not* a `ViewModifier` that writes `\.palette`. A view's own
/// `@Environment(\.palette)` resolves against what its parent handed down, not
/// against what its own body sets — so a root that both publishes the palette
/// and draws with it would silently draw with the default. Views that need the
/// value read it here and publish it downward themselves.
struct PaletteInputs: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    func resolved(monochromeEnabled: Bool) -> ResolvedPalette {
        .resolve(
            colorScheme: colorScheme,
            systemContrast: systemContrast,
            differentiateWithoutColor: withoutColour,
            monochromeEnabled: monochromeEnabled
        )
    }
}
