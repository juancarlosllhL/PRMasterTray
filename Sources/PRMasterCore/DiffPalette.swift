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
}
