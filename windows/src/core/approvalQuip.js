// The remark posted alongside an approval, chosen from what the row already knows.
// Port of ApprovalQuip.swift: this owns what it says, and above all which bucket
// wins when several match. (Whether to post one at all is a setting.)

// Ordered by precedence — the first match wins. What a reviewer would actually
// remark on: the shape of the diff first, what the title claims second, and the
// state of the row last.
export const BUCKETS = [
  "deletionHeavy", "countlessFiles", "enormous", "huge", "big", "veryManyFiles", "manyFiles", "tiny", "singleFile",
  "revert", "fixes", "refactor", "dependencies", "tests", "documentation",
  "checksFailing", "checksPending", "forgotten", "fresh", "piledOn", "generic",
];

const FORGOTTEN_AFTER_MS = 14 * 86_400_000;
const FRESH_WITHIN_MS = 3_600_000;

// Tokenised on non-alphanumerics, which is what makes a gitmoji shortcode work as
// a keyword — `:bug:` and `bug` tokenise alike — and what keeps `fix` from
// matching `prefix`. Underscores are kept, or `:arrow_up:` would come apart into
// words nobody wrote.
const TITLE_KEYWORDS = [
  ["revert", ["revert", "reverts", "reverting", "reverted", "rewind"]],
  ["fixes", ["fix", "fixes", "fixed", "bug", "bugfix", "hotfix", "patch", "ambulance"]],
  ["refactor", ["refactor", "refactored", "refactoring", "recycle", "cleanup", "simplify"]],
  ["dependencies", ["bump", "bumps", "deps", "dependency", "dependencies", "chore", "arrow_up", "dependabot", "renovate"]],
  ["tests", ["test", "tests", "testing", "coverage", "white_check_mark"]],
  ["documentation", ["doc", "docs", "documentation", "readme", "typo", "memo", "changelog"]],
];

function titleBucket(title) {
  const words = new Set(title.toLowerCase().split(/[^\p{L}\p{N}_]+/u).filter(Boolean));
  return TITLE_KEYWORDS.find(([, list]) => list.some((w) => words.has(w)))?.[0] ?? null;
}

export function bucketFor(request, now) {
  const lines = request.additions + request.deletions;
  const age = now - new Date(request.createdAt);

  if (request.deletions >= 100 && request.deletions >= 3 * request.additions) return "deletionHeavy";
  if (request.changedFiles > 100) return "countlessFiles";
  if (lines > 5000) return "enormous";
  if (lines > 2000) return "huge";
  if (lines >= 1000) return "big";
  if (request.changedFiles > 50) return "veryManyFiles";
  if (request.changedFiles > 20) return "manyFiles";
  if (lines < 50) return "tiny";
  if (request.changedFiles === 1) return "singleFile";

  const claimed = titleBucket(request.title);
  if (claimed) return claimed;

  if (request.checks === "FAILURE" || request.checks === "ERROR") return "checksFailing";
  if (request.checks === "PENDING" || request.checks === "EXPECTED") return "checksPending";

  if (age > FORGOTTEN_AFTER_MS) return "forgotten";
  if (age < FRESH_WITHIN_MS) return "fresh";
  if (request.reviewDecision === "APPROVED") return "piledOn";
  return "generic";
}

// A line for that pull request. `pick` is injected so the choice can be pinned in
// tests; it is handed the number of lines available, and clamped rather than
// trusted: the quip is a joke, and a joke has no business failing an approval.
export function quipFor(request, now, pick = (n) => Math.floor(Math.random() * n)) {
  const available = linesFor(bucketFor(request, now));
  const wanted = pick(available.length);
  const index = Math.min(Math.max(Number.isFinite(wanted) ? Math.trunc(wanted) : 0, 0), available.length - 1);
  return available[index];
}

// Every line this app is willing to post, grouped so a bucket can be read and
// edited whole — which is how the list gets reviewed.
const LINES = {
  deletionHeavy: [
    "Approved, enthusiastically. Deleted code is the only code that never breaks. 🔥",
    "Approved. Net negative diff — my favourite genre. 📉",
    "Approved. You took more out than you put in, which is the highest form of engineering. ✂️",
    "Approved. Fewer lines to read next time, and fewer lines to be wrong. 🧹",
    "Approved. Nothing ages better than code that is no longer there. 🗑️",
  ],
  countlessFiles: [
    "Approved. A hundred-plus files. Whatever this was refactoring, it lost. 🌍",
    "Approved. I reviewed a representative sample and made peace with the rest. 🙏",
    "Approved. I opened the files tab and it opened a support ticket. 📂",
    "Approved. Somewhere in here is the change, and the rest came along for the ride. 🧭",
  ],
  enormous: [
    "Approved. Five thousand lines. My scroll wheel has filed a grievance. 🖱️",
    "Approved. This PR has more lines than the service it belongs to had last year. 🏗️",
    "Approved. Reviewing this was a lifestyle, not a task. 🧘",
    "Approved. GitHub stopped rendering the diff before I stopped reading it. 🫠",
    "Approved. I began this review with a different haircut. 💇",
  ],
  huge: [
    "Approved. I scrolled. I kept scrolling. At some point I made peace with it. 🎢",
    "Approved. Somewhere in these thousands of lines is a bug we'll meet in six months. Good to know it's coming. 🔮",
    "Approved. Two thousand lines is not a diff, it's a commitment. 💍",
    "Approved. I read this in instalments, like a mortgage. 🏦",
  ],
  big: [
    "Approved. Four figures of diff and I still clicked the button. Respect. 💪",
    "Approved. This is less a pull request and more a chapter. 📖",
    "Approved. A thousand lines that never once asked for a second opinion. 🗿",
    "Approved. I'd have asked you to split it, but it had already split my afternoon. 🪓",
  ],
  veryManyFiles: [
    "Approved. At this file count it's not a change, it's a relocation. 🚚",
    "Approved. Fifty-odd files and, I am told, one intention. 🗺️",
    "Approved. Whole directories changed hands today. 🏘️",
    "Approved. The pattern held for the first ten files, so I extended you credit on the rest. 💳",
  ],
  manyFiles: [
    "Approved. Twenty-odd files touched — hope the blame view is ready. 🗂️",
    "Approved. Twenty files that all agree with each other, which is the good kind of sprawl. 🧩",
    "Approved. A find-and-replace with ambitions. 🔁",
    "Approved. Wide but shallow, which is the merciful combination. 🌊",
  ],
  tiny: [
    "Approved. A diff I could actually read in full — thank you for your service. 🔍",
    "Approved. Small, sharp, done. This is the good stuff. 🤏",
    "Approved in under a minute, because you kept it under fifty lines. 📏",
    "Approved. The whole change fit on one screen and I'm still emotional about it. 🖥️",
    "Approved. That's a review, not an expedition. 🥾",
  ],
  singleFile: [
    "Approved. One file, one purpose, zero drama. 🎯",
    "Approved. One file, so there's exactly one place to look when it misbehaves. 🔦",
    "Approved. Nothing to cross-reference, nothing to regret. 📄",
    "Approved. Single file, single reviewer, single click. ☝️",
  ],
  revert: [
    "Approved. Undoing is also engineering. ↩️",
    "Approved. We're all pretending this never happened. 🙈",
    "Approved. Main goes back to how it was, and so do we. ⏪",
    "Approved. Every revert is a lesson with a merge commit attached. 🎓",
  ],
  fixes: [
    "Approved. One bug down, the backlog barely noticed. 🐛",
    "Approved. Fix now, blameless post-mortem later. 🔧",
    "Approved. It was broken, now it isn't, and that's the whole review. 🩹",
    "Approved. The bug had a good run. 🪦",
    "Approved. Well found, and found before a customer found it. 🕵️",
  ],
  refactor: [
    "Approved. Same behaviour, better vibes. ♻️",
    "Approved. Fewer lines is my favourite kind of feature. ✨",
    "Approved. Nothing works differently and everything reads better. 🧼",
    "Approved. The next person to open this file owes you a coffee. ☕️",
    "Approved. Moving the mess into better-shaped boxes still counts. 📦",
  ],
  dependencies: [
    "Approved. Another dependency dragged into the present day. 📦",
    "Approved. Robots do the typing, humans click the button. 🤖",
    "Approved. The lockfile has spoken and I'm not going to argue with it. 🔒",
    "Approved, trusting that the changelog was honest. 🤞",
    "Approved. One version closer to whatever breaks next quarter. 🗓️",
  ],
  tests: [
    "Approved. Tests: the only PR nobody argues about. 🧪",
    "Approved. Future you is grateful, present you is tired. 🟩",
    "Approved. Coverage went up and nobody had to be talked into it. 📈",
    "Approved. Writing the test after the bug is still writing the test. 🧾",
    "Approved. Green today, and a tripwire for whoever refactors this next. 🪤",
  ],
  documentation: [
    "Approved. The docs thank you on behalf of everyone who never reads them. 📚",
    "Approved. Fixing a typo is the purest form of open source. ✏️",
    "Approved. Someone reading this at two in the morning will feel less alone. 🌙",
    "Approved. The README now describes the software we actually have. 🗺️",
    "Approved. No code changed, so nothing can break. My favourite guarantee. 🛡️",
  ],
  checksFailing: [
    "Approved on the code, not on CI — the red ticks are yours to argue with. 🔴",
    "Approved. CI is having a moment; the diff is fine. 🤷",
    "Approved. The logic is sound, the pipeline is a separate negotiation. 🤝",
    "Approved. I read the diff, not the build log. One of us has to stay hopeful. 🎈",
  ],
  checksPending: [
    "Approved while CI is still thinking about it. Optimism as a review strategy. ⏳",
    "Approved ahead of the checks — you have my vote, CI has the final word. 🟡",
    "Approved. I got here before the pipeline did, which rarely happens. 🏁",
    "Approved. The spinner and I have an understanding. 🔄",
  ],
  forgotten: [
    "Approved. This PR has been open long enough to develop a personality. Free at last. 🕰️",
    "Sorry for the wait — approved. Your branch has seen things. 👴",
    "Approved. This one's been open so long the style guide changed twice. 📜",
    "Approved. Two weeks in the queue and it still merges cleanly. Remarkable. 🏺",
    "Approved. Rebasing it is now the hard part, and that one's on you. 🧗",
  ],
  fresh: [
    "Approved before the coffee went cold. ☕️",
    "That was quick, wasn't it? Approved. ⚡️",
    "Approved. The notification hadn't finished vibrating. 📳",
    "Opened and approved inside the hour. Savour it, this won't happen again. 🍀",
  ],
  piledOn: [
    "Approved — piling on. Consider this a second signature on the same form. 🖊️",
    "Approved. You had a quorum, now you have a crowd. 👥",
    "Approved. Already green, but I wanted to be in the photo. 📸",
    "Approved. Redundant, agreeable, on the record. 🗳️",
  ],
  generic: [
    "Approved. Shipped straight from the tray — no IDE was harmed in the making of this review. 🚀",
    "LGTM. I read it, I understood it, I have chosen to believe in you. ✅",
    "Approved from a tray icon the size of a postage stamp. That's how much I trust this one.",
    "Ship it. The green tick has spoken. 🟢",
    "Approved. Nothing to remark on, which is its own kind of compliment. 🫡",
    "Approved. Read, considered, waved through. 👌",
  ],
};

export const linesFor = (bucket) => LINES[bucket];
