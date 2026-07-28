/// Renders `:shortcode:` sequences in pull request titles as emoji.
///
/// GitHub substitutes these server-side in its own UI, but the GraphQL `title`
/// field returns the raw text, so a title written `:sparkles: add thing` reaches
/// this app verbatim and would otherwise show the shortcode instead of the glyph.
///
/// Substitution is plain string replacement by design. Titles are user content
/// that this app never authored; anything HTML- or markup-shaped would be a
/// parser pointed at untrusted input for a purely cosmetic gain.
public enum EmojiShortcodes {

    /// The gitmoji set (gitmoji.dev), plus the handful of GitHub codes that turn
    /// up in PR titles often enough to matter.
    ///
    /// Codes outside this table are left exactly as written. Showing `:foo:` is
    /// honest about not knowing it; stripping or guessing would not be.
    static let map: [String: String] = [
        "art": "🎨", "zap": "⚡️", "fire": "🔥", "bug": "🐛",
        "ambulance": "🚑️", "sparkles": "✨", "memo": "📝", "rocket": "🚀",
        "lipstick": "💄", "tada": "🎉", "white_check_mark": "✅", "lock": "🔒️",
        "closed_lock_with_key": "🔐", "bookmark": "🔖", "rotating_light": "🚨",
        "construction": "🚧", "green_heart": "💚", "arrow_down": "⬇️",
        "arrow_up": "⬆️", "pushpin": "📌", "construction_worker": "👷",
        "chart_with_upwards_trend": "📈", "recycle": "♻️", "heavy_plus_sign": "➕",
        "heavy_minus_sign": "➖", "wrench": "🔧", "hammer": "🔨",
        "globe_with_meridians": "🌐", "pencil2": "✏️", "poop": "💩",
        "rewind": "⏪️", "twisted_rightwards_arrows": "🔀", "package": "📦️",
        "alien": "👽️", "truck": "🚚", "page_facing_up": "📄", "boom": "💥",
        "bento": "🍱", "wheelchair": "♿️", "bulb": "💡", "beers": "🍻",
        "speech_balloon": "💬", "card_file_box": "🗃️", "loud_sound": "🔊",
        "mute": "🔇", "busts_in_silhouette": "👥", "children_crossing": "🚸",
        "building_construction": "🏗️", "iphone": "📱", "clown_face": "🤡",
        "egg": "🥚", "see_no_evil": "🙈", "camera_flash": "📸", "alembic": "⚗️",
        "mag": "🔍️", "label": "🏷️", "seedling": "🌱",
        "triangular_flag_on_post": "🚩", "goal_net": "🥅", "dizzy": "💫",
        "wastebasket": "🗑️", "passport_control": "🛂", "adhesive_bandage": "🩹",
        "monocle_face": "🧐", "coffin": "⚰️", "test_tube": "🧪", "necktie": "👔",
        "stethoscope": "🩺", "bricks": "🧱", "technologist": "🧑‍💻",
        "money_with_wings": "💸", "thread": "🧵", "safety_vest": "🦺",
        "airplane": "✈️",
        // Not gitmoji, but common in PR titles.
        "warning": "⚠️", "eyes": "👀", "x": "❌", "+1": "👍", "-1": "👎",
    ]

    /// Scanned by hand rather than with `Regex`.
    ///
    /// `Regex` is not `Sendable`, so the pattern cannot be hoisted into a `static
    /// let` under strict concurrency, and rebuilding one per row to render a list
    /// is worse than the dozen lines below.
    public static func render(_ text: String) -> String {
        guard text.contains(":") else { return text }

        var out = ""
        var rest = text[...]

        while let open = rest.firstIndex(of: ":") {
            let start = rest.index(after: open)
            // The closing colon must be the very next non-shortcode character.
            // Scanning further would let a lone colon in ordinary prose reach
            // across the rest of the title looking for a partner.
            let end = rest[start...].firstIndex { !isShortcodeCharacter($0) }

            guard let end,
                  rest[end] == ":",
                  end > start,  // `::` is not an empty shortcode
                  let glyph = map[String(rest[start..<end])]
            else {
                // Not a shortcode. Emit through the opening colon and carry on
                // from the next character, so `12:30:45` gets a second look at
                // its second colon.
                out += rest[...open]
                rest = rest[start...]
                continue
            }

            out += rest[..<open]
            out += glyph
            rest = rest[rest.index(after: end)...]
        }

        out += rest
        return out
    }

    private static func isShortcodeCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber
            || character == "_" || character == "+" || character == "-"
    }
}

extension PullRequest {
    /// The title as a human should see it.
    ///
    /// Every user-facing surface uses this; `title` is the raw wire value and is
    /// only appropriate where the exact bytes matter.
    public var displayTitle: String { EmojiShortcodes.render(title) }
}
