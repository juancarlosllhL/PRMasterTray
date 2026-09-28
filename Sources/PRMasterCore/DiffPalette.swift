/// What a diff row is painted as. Headers share one tint.
public enum DiffLineTint: Sendable, Equatable, CaseIterable {
    case context, added, removed, header
}

/// Diff colours for the review window. Worst ratios, text or token against any
/// row: standard 5.46:1, increased 7.95:1, monochrome 12.08:1.
extension Palette {

    public static func diffText(appearance: AppearanceMode, contrast: ContrastMode) -> RGB {
        switch (appearance, contrast) {
        case (.light, .standard): return .hex(0x1F2328)
        case (.light, _): return .hex(0x000000)
        case (.dark, .standard): return .hex(0xE6EDF3)
        case (.dark, _): return .hex(0xFFFFFF)
        }
    }

    public static func diffBackground(
        _ tint: DiffLineTint, appearance: AppearanceMode, contrast: ContrastMode
    ) -> RGB {
        switch (appearance, contrast == .monochrome, tint) {
        case (.light, false, .context): return .hex(0xFFFFFF)
        case (.light, false, .added): return .hex(0xE6FFEC)
        case (.light, false, .removed): return .hex(0xFFEBE9)
        case (.light, false, .header): return .hex(0xF6F8FA)
        case (.light, true, .context): return .hex(0xFFFFFF)
        case (.light, true, .added): return .hex(0xF0F0F0)
        case (.light, true, .removed): return .hex(0xE4E4E4)
        case (.light, true, .header): return .hex(0xEBEBEB)
        case (.dark, false, .context): return .hex(0x1E1E1E)
        case (.dark, false, .added): return .hex(0x203124)
        case (.dark, false, .removed): return .hex(0x342322)
        case (.dark, false, .header): return .hex(0x2B2B2B)
        case (.dark, true, .context): return .hex(0x1E1E1E)
        case (.dark, true, .added): return .hex(0x2A2A2A)
        case (.dark, true, .removed): return .hex(0x363636)
        case (.dark, true, .header): return .hex(0x262626)
        }
    }

    /// In monochrome every token is the text colour; the app varies weight instead.
    public static func token(_ kind: TokenKind, appearance: AppearanceMode, contrast: ContrastMode) -> RGB {
        switch (appearance, contrast, kind) {
        case (_, .monochrome, _): return diffText(appearance: appearance, contrast: contrast)
        case (.light, .standard, .keyword): return .hex(0xA0111F)
        case (.light, .standard, .string): return .hex(0x0A3069)
        case (.light, .standard, .comment): return .hex(0x57606A)
        case (.light, .standard, .number): return .hex(0x0550AE)
        case (.light, .increased, .keyword): return .hex(0x6E0B14)
        case (.light, .increased, .string): return .hex(0x032563)
        case (.light, .increased, .comment): return .hex(0x3D444D)
        case (.light, .increased, .number): return .hex(0x023B95)
        case (.dark, .standard, .keyword): return .hex(0xFF7B72)
        case (.dark, .standard, .string): return .hex(0xA5D6FF)
        case (.dark, .standard, .comment): return .hex(0x9DA5AE)
        case (.dark, .standard, .number): return .hex(0x79C0FF)
        case (.dark, .increased, .keyword): return .hex(0xFFB1AB)
        case (.dark, .increased, .string): return .hex(0xCAE8FF)
        case (.dark, .increased, .comment): return .hex(0xC9D1D9)
        case (.dark, .increased, .number): return .hex(0xB6DCFF)
        }
    }
}
