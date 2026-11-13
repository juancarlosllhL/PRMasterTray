import { ageLabel, isStale } from "./staleness.js";

// The macOS app defaults to one month; null (off) is passed explicitly.
const DEFAULT_STALE_DAYS = 30;

const LABELS = {
  draft: "Draft",
  conflicted: "Merge conflicts",
  checksFailing: "Checks failing",
  checksPending: "Checks running",
  behind: "Behind base branch",
  quillComments: "Quill comments",
  unresolvedComments: "Unresolved comments",
  blocked: "Waiting for review",
  ready: "Ready to merge",
};

// Pull requests as display rows, ready ones first. Only github.com links are
// kept: titles and URLs come from the network and end up in shell.openExternal.
export function rows(prs, now = new Date(), staleDays = DEFAULT_STALE_DAYS) {
  const openable = prs.filter((p) => p.url.startsWith("https://github.com/"));
  const ready = openable.filter((p) => p.readiness === "ready");
  const rest = openable.filter((p) => p.readiness !== "ready");
  return [...ready, ...rest].map((p) => ({
    id: p.id,
    repo: p.repo,
    number: p.number,
    title: p.title,
    readiness: p.readiness,
    status: LABELS[p.readiness],
    url: p.url,
    stale: isStale(p.createdAt, now, staleDays),
    age: ageLabel(p.createdAt, now),
  }));
}

const SHIPMENT_LABELS = {
  pending: () => "Merged",
  building: () => "Building…",
  failed: (s) => `Failed: ${s.name}`,
  released: (s) => `Released ${s.version}`,
};

// Where a row goes when clicked: the pipeline while there is one worth
// watching, the release once there is one, the PR when there is nothing else.
// Links come from the network, so only https ones are ever offered.
export function shipmentRows(shipments) {
  return shipments
    .map(({ pr, status, environments = [] }) => ({
      id: pr.id,
      number: pr.number,
      title: pr.title,
      repo: pr.repo,
      kind: status.kind,
      label: SHIPMENT_LABELS[status.kind](status),
      url: status.url ?? pr.url,
      prURL: pr.url,
      chips: environments.flatMap(chip),
    }))
    .filter((r) => r.url.startsWith("https://"));
}

const ENV_NAMES = { staging: "stg", production: "prod" };

// carrying: the change is in what runs there. awaiting: that environment runs
// something without it. unknown gets no chip. When regions disagree the version
// is the lowest of them, so it is shown as a floor: at least this, further along elsewhere.
function chip({ environment, status, regionsAgree }) {
  if (status.kind === "unknown") return [];
  return [{ label: `${ENV_NAMES[environment]} ${regionsAgree ? "" : "≥"}${status.version}`, kind: status.kind }];
}
