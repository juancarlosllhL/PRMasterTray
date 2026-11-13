// Renders `:shortcode:` sequences in pull request titles as emoji. Port of
// EmojiShortcodes.swift.
//
// GitHub substitutes these server-side in its own UI, but the GraphQL `title` field
// returns the raw text, so a title written `:sparkles: add thing` reaches this app
// verbatim. Substitution is plain string replacement by design: titles are user
// content this app never authored, and anything markup-shaped would be a parser
// pointed at untrusted input for a purely cosmetic gain.

// The gitmoji set (gitmoji.dev), plus the handful of GitHub codes that turn up in
// PR titles often enough to matter. Codes outside this table are left exactly as
// written: showing `:foo:` is honest about not knowing it; stripping or guessing is not.
export const EMOJI = {
  art: "🎨", zap: "⚡️", fire: "🔥", bug: "🐛",
  ambulance: "🚑️", sparkles: "✨", memo: "📝", rocket: "🚀",
  lipstick: "💄", tada: "🎉", white_check_mark: "✅", lock: "🔒️",
  closed_lock_with_key: "🔐", bookmark: "🔖", rotating_light: "🚨",
  construction: "🚧", green_heart: "💚", arrow_down: "⬇️",
  arrow_up: "⬆️", pushpin: "📌", construction_worker: "👷",
  chart_with_upwards_trend: "📈", recycle: "♻️", heavy_plus_sign: "➕",
  heavy_minus_sign: "➖", wrench: "🔧", hammer: "🔨",
  globe_with_meridians: "🌐", pencil2: "✏️", poop: "💩",
  rewind: "⏪️", twisted_rightwards_arrows: "🔀", package: "📦️",
  alien: "👽️", truck: "🚚", page_facing_up: "📄", boom: "💥",
  bento: "🍱", wheelchair: "♿️", bulb: "💡", beers: "🍻",
  speech_balloon: "💬", card_file_box: "🗃️", loud_sound: "🔊",
  mute: "🔇", busts_in_silhouette: "👥", children_crossing: "🚸",
  building_construction: "🏗️", iphone: "📱", clown_face: "🤡",
  egg: "🥚", see_no_evil: "🙈", camera_flash: "📸", alembic: "⚗️",
  mag: "🔍️", label: "🏷️", seedling: "🌱",
  triangular_flag_on_post: "🚩", goal_net: "🥅", dizzy: "💫",
  wastebasket: "🗑️", passport_control: "🛂", adhesive_bandage: "🩹",
  monocle_face: "🧐", coffin: "⚰️", test_tube: "🧪", necktie: "👔",
  stethoscope: "🩺", bricks: "🧱", technologist: "🧑‍💻",
  money_with_wings: "💸", thread: "🧵", safety_vest: "🦺",
  airplane: "✈️",
  // Not gitmoji, but common in PR titles.
  warning: "⚠️", eyes: "👀", x: "❌", "+1": "👍", "-1": "👎",
};

const isShortcodeCharacter = (c) => /^[A-Za-z0-9_+-]$/.test(c);

function substitute(text, transform) {
  if (!text.includes(":")) return text;
  let out = "";
  let rest = text;
  for (let open = rest.indexOf(":"); open >= 0; open = rest.indexOf(":")) {
    const start = open + 1;
    // The closing colon must be the very next non-shortcode character: scanning
    // further would let a lone colon in prose reach across the title for a partner.
    let end = start;
    while (end < rest.length && isShortcodeCharacter(rest[end])) end++;
    const glyph = end < rest.length && rest[end] === ":" && end > start ? EMOJI[rest.slice(start, end)] : undefined;
    if (glyph === undefined || !Object.hasOwn(EMOJI, rest.slice(start, end))) {
      // Not a shortcode. Emit through the opening colon and carry on from the
      // next character, so `12:30:45` gets a second look at its second colon.
      out += rest.slice(0, start);
      rest = rest.slice(start);
      continue;
    }
    out += rest.slice(0, open) + transform(glyph);
    rest = rest.slice(end + 1);
  }
  return out + rest;
}

export const renderEmoji = (text) => substitute(text, (glyph) => glyph);

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const isEmoji = (cluster) => cluster.includes("️") || /^\p{Emoji_Presentation}/u.test(cluster);

// Both forms of it: the shortcode this app would have rendered, and a glyph the
// author typed straight into the title.
export function stripEmoji(text) {
  const plain = [...graphemes.segment(substitute(text, () => ""))].map((s) => s.segment).filter((c) => !isEmoji(c)).join("");
  return plain.split(" ").filter(Boolean).join(" ");
}
