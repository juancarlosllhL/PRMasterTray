// Jira Cloud over HTTP Basic (site, email and API token), and moving an issue
// between board columns. Port of JiraClient.swift, JiraCredentials.swift,
// JiraRoute.swift, JiraMove.swift and JiraField.swift.
import { BOARD_LANES, laneForStatusId, laneIndex, laneOfStatus, priorityFromId } from "./jira.js";

// code: unauthorized | rateLimited | http | moveRefused | decoding | network | invalidCredentials
export class JiraError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// ---- Credentials ------------------------------------------------------------

// OAuth is not an option: Atlassian's 3LO flow still requires a client secret, and
// no distributable binary can hold one. The token is a private field, so it is in
// neither the JSON nor the description of a credential.
export class JiraCredentials {
  #apiToken;

  constructor(baseURL, email, apiToken) {
    this.baseURL = baseURL;
    this.email = email;
    this.#apiToken = apiToken;
  }

  get basicAuthHeader() {
    return `Basic ${Buffer.from(`${this.email}:${this.#apiToken}`).toString("base64")}`;
  }

  toString() {
    return `JiraCredentials(${this.baseURL}, ${this.email})`;
  }

  [Symbol.for("nodejs.util.inspect.custom")]() {
    return this.toString();
  }
}

export function createCredentials({ baseURL, email, apiToken }) {
  const site = baseURL.trim().replace(/\/+$/, "");
  const mail = email.trim();
  const token = apiToken.trim();
  let host = "";
  try {
    host = new URL(site).hostname;
  } catch {
    // reported below
  }
  if (!site.toLowerCase().startsWith("https://") || !host) {
    throw new JiraError("invalidCredentials", "The site must be an https:// address, like https://acme.atlassian.net");
  }
  if (!mail.includes("@")) throw new JiraError("invalidCredentials", "That does not look like an email address.");
  if (!token) throw new JiraError("invalidCredentials", "The API token is empty.");
  return new JiraCredentials(site, mail, token);
}

// ---- Dates and queries ------------------------------------------------------

// Jira sends `2026-09-10T08:00:00.000+0000`, whose offset has no colon.
export function jiraDate(raw) {
  if (typeof raw !== "string") return null;
  const date = new Date(raw.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

// Everything still open, plus whatever reached Done inside the window.
export function assignedQuery(windowDays) {
  if (windowDays == null) return "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC";
  return `assignee = currentUser() AND (statusCategory != Done OR statusCategoryChangedDate >= -${windowDays}d) ORDER BY updated DESC`;
}

const ISSUE_FIELDS = "key,summary,status,issuetype,updated,created,priority,statuscategorychangedate";
const PAGE_SIZE = 100;
const SEARCH_PATH = "/rest/api/3/search/jql"; // the old /rest/api/3/search answers HTTP 410
const BUG_TYPE_ID = "10004"; // only the ACME Bug workflow has a validator demanding the fields Jira calls optional

function decodeIssue(node) {
  const f = node.fields ?? {};
  return {
    key: node.key,
    summary: f.summary ?? "",
    statusName: f.status?.name ?? "",
    statusID: f.status?.id ?? null,
    statusCategory: f.status?.statusCategory?.key ?? "__unknown",
    issueType: f.issuetype?.name ?? "",
    priority: priorityFromId(f.priority?.id),
    updatedAt: jiraDate(f.updated) ?? "1970-01-01T00:00:00.000Z",
    createdAt: jiraDate(f.created),
    categoryChangedAt: jiraDate(f.statuscategorychangedate),
  };
}

const decodeStatus = (raw) => ({ name: raw.name ?? "", category: raw.statusCategory?.key ?? "__unknown", id: raw.id ?? null });

// ---- Fields a transition's screen asks for ----------------------------------

const REMARK_PREFIX = "PM:";

// Every one is treated as required: on ACME, Jira reports the Bug fields as optional
// while a workflow validator refuses the transition without them. kind is
// { type: "option", allowed: [...] } | { type: "text" } | { type: "richText" }.
export class JiraField {
  constructor({ id, name, kind }) {
    this.id = id;
    this.name = name;
    this.kind = kind;
  }

  // Lansweeper's convention: every Remark opens with "PM:".
  get takesRemarkPrefix() {
    return this.name.toLowerCase() === "remark";
  }

  get addedPrefix() {
    return this.takesRemarkPrefix ? REMARK_PREFIX : null;
  }

  // What is sent to Jira: trimmed, and a Remark given "PM: " unless it has it.
  normalized(value) {
    const trimmed = value.trim();
    if (!this.takesRemarkPrefix) return trimmed;
    if (!trimmed.toLowerCase().startsWith(REMARK_PREFIX.toLowerCase())) return `${REMARK_PREFIX} ${trimmed}`;
    return REMARK_PREFIX + trimmed.slice(REMARK_PREFIX.length);
  }

  problem(value) {
    const sent = this.normalized(value);
    if (this.kind.type === "option") return this.kind.allowed.includes(sent) ? null : `Choose a ${this.name}.`;
    const body = this.takesRemarkPrefix ? sent.slice(REMARK_PREFIX.length) : sent;
    return body.trim() === "" ? `${this.name} is required.` : null;
  }
}

// Jira's v3 API takes a multi-line text field only as a document.
function encodeField(value, kind) {
  if (kind.type === "option") return { value };
  if (kind.type === "text") return value;
  return {
    type: "doc",
    version: 1,
    content: value.split("\n").map((line) => ({ type: "paragraph", content: line === "" ? [] : [{ type: "text", text: line }] })),
  };
}

function fieldKind(field) {
  switch (field.schema?.custom?.split(":").pop()) {
    case "select":
    case "radiobuttons":
      return { type: "option", allowed: (field.allowedValues ?? []).map((v) => v.value ?? v.name).filter(Boolean) };
    case "textarea":
      return { type: "richText" };
    case "textfield":
      return { type: "text" };
    default:
      return null;
  }
}

function decodeTransitions(body) {
  const status = body.fields?.status;
  if (!status?.name) throw new JiraError("decoding", "transitions response carried no status");
  const isBug = body.fields?.issuetype?.id === BUG_TYPE_ID;
  const transitions = (body.transitions ?? []).map((node) => {
    const screen = Object.entries(node.fields ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return {
      id: node.id,
      to: decodeStatus(node.to),
      isGlobal: node.isGlobal ?? false,
      // A field Jira insists on, which the app has no way to ask for.
      needsInput: screen.some(([, f]) => f.required === true && fieldKind(f) === null),
      fields: screen.flatMap(([id, f]) => {
        const kind = fieldKind(f);
        return kind && (isBug || f.required === true) ? [new JiraField({ id, name: f.name ?? id, kind })] : [];
      }),
    };
  });
  return [decodeStatus(status), transitions];
}

// Jira puts general reasons in `errorMessages` and per-field ones in `errors`.
function refusal(body, status) {
  const reasons = [...(body?.errorMessages ?? []), ...Object.entries(body?.errors ?? {}).sort(([a], [b]) => (a < b ? -1 : 1)).map(([, v]) => v)];
  return reasons.length ? reasons.join(" ") : `Jira answered HTTP ${status}.`;
}

// ---- The client -------------------------------------------------------------

// The key lands in a URL path, and a dropped string can come from any app.
const checked = (key) => {
  if (!/^[A-Z][A-Z0-9_]*-[0-9]+$/.test(key)) throw new JiraError("moveRefused", `“${key}” is not a Jira issue key.`);
  return key;
};

export function createJiraClient({ credentials, fetchImpl = fetch }) {
  const headers = () => ({ Authorization: credentials.basicAuthHeader, Accept: "application/json", "User-Agent": "PRMaster" });

  // `refusing` is for moves: there a 403 means no permission to transition, not a
  // bad token, and Jira explains every 4xx in the body.
  async function send(url, init = {}, { refusing = false } = {}) {
    let res;
    try {
      res = await fetchImpl(url, { ...init, headers: { ...headers(), ...init.headers } });
    } catch (e) {
      throw new JiraError("network", `Jira could not be reached: ${e.message}`);
    }
    if (refusing && [400, 403, 404, 409].includes(res.status)) {
      let body = null;
      try {
        body = await res.json();
      } catch {
        // Jira did not explain: the status will have to do.
      }
      throw new JiraError("moveRefused", refusal(body, res.status));
    }
    if (res.status === 200 || res.status === 204) return res.status === 204 ? null : res.json();
    if (res.status === 401 || res.status === 403) throw new JiraError("unauthorized", "Jira refused the sign-in: check the email and the API token.");
    if (res.status === 429) throw new JiraError("rateLimited", "Jira is rate limiting; try again in a minute.");
    throw new JiraError("http", `Jira answered HTTP ${res.status}.`);
  }

  return {
    // Every issue assigned to the signed-in user that is not done, plus the ones finished inside the window.
    async assignedIssues(windowDays) {
      const issues = [];
      let pageToken = null;
      for (;;) {
        const url = new URL(credentials.baseURL + SEARCH_PATH);
        url.searchParams.set("jql", assignedQuery(windowDays));
        url.searchParams.set("fields", ISSUE_FIELDS);
        url.searchParams.set("maxResults", String(PAGE_SIZE));
        if (pageToken) url.searchParams.set("nextPageToken", pageToken);
        const page = await send(url);
        if (!Array.isArray(page?.issues)) throw new JiraError("decoding", "search response carried no issues");
        issues.push(...page.issues.map(decodeIssue));
        if (page.isLast === true || !page.nextPageToken) break;
        pageToken = page.nextPageToken;
      }
      return issues;
    },

    // Confirms the credentials and answers with who they belong to.
    async verify() {
      const me = await send(new URL(`${credentials.baseURL}/rest/api/3/myself`));
      if (!me?.displayName) throw new JiraError("decoding", "myself response carried no displayName");
      return me.displayName;
    },

    async transitions(key) {
      const url = new URL(`${credentials.baseURL}/rest/api/3/issue/${checked(key)}`);
      url.searchParams.set("fields", "status,issuetype");
      url.searchParams.set("expand", "transitions.fields");
      return decodeTransitions(await send(url, {}, { refusing: true }));
    },

    async perform(transition, key, values) {
      const url = `${credentials.baseURL}/rest/api/3/issue/${checked(key)}/transitions`;
      const fields = {};
      for (const f of transition.fields) if (f.id in values) fields[f.id] = encodeField(values[f.id], f.kind);
      const body = { transition: { id: transition.id }, ...(Object.keys(fields).length ? { fields } : {}) };
      await send(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }, { refusing: true });
    },
  };
}

// ---- Choosing the next step -------------------------------------------------

const laneOfJiraStatus = (s) => laneOfStatus({ statusName: s.name, statusCategory: s.category, statusID: s.id });

// Cancel is global and category done, and some sites ask no resolution for it.
const namesALane = (s) => (s.id != null && laneForStatusId(s.id) !== null) || BOARD_LANES.some((l) => l.title.toLowerCase() === s.name.toLowerCase());

// Picks one transition at a time, because the workflow itself is readable only by
// Jira administrators: only what the current status offers is known.
export function nextHop(current, target, offered, visited) {
  const here = laneOfJiraStatus(current);
  if (here === null) return null;

  const usable = offered.flatMap((t) => {
    if (t.needsInput || visited.has(t.to.name) || (t.isGlobal && !namesALane(t.to))) return [];
    const lane = laneOfJiraStatus(t.to);
    return lane ? [{ t, lane }] : [];
  });

  const arriving = usable.filter((u) => u.lane === target).map((u) => u.t);
  if (arriving.length) {
    const title = BOARD_LANES[laneIndex(target)].title.toLowerCase();
    return arriving.find((t) => t.to.name.toLowerCase() === title) ?? arriving.find((t) => !t.isGlobal) ?? arriving[0];
  }

  const distance = (lane) => Math.abs(laneIndex(lane) - laneIndex(target));
  const rank = (u) => [distance(u.lane), u.t.isGlobal ? 1 : 0];
  const better = (a, b) => (a[0] !== b[0] ? a[0] < b[0] : a[1] < b[1]);
  let best = null;
  for (const u of usable) {
    if (distance(u.lane) > distance(here)) continue; // never a step away from the target
    if (!best || better(rank(u), rank(best))) best = u; // strict: Jira's own order on a tie
  }
  return best?.t ?? null;
}

// ---- Walking to a column ----------------------------------------------------

const MAX_HOPS = 6;

// Re-reads the status before every hop, in case the browser moved it meanwhile.
// Outcomes: moved {to} | stopped {at, target} | failed {message, leftAt} | cancelled {leftAt}.
export async function moveIssue({ client, askFor = async () => null }, key, target) {
  const visited = new Set();
  let leftAt = null;
  try {
    for (let hops = 0; hops < MAX_HOPS; hops++) {
      const [status, offered] = await client.transitions(key);
      if (laneOfJiraStatus(status) === target) return { kind: "moved", to: status };
      visited.add(status.name);
      const hop = nextHop(status, target, offered, visited);
      if (!hop) return { kind: "stopped", at: status, target };
      let values = {};
      if (hop.fields.length) {
        const answer = await askFor({ key, from: status, to: hop.to, fields: hop.fields });
        if (!answer) return { kind: "cancelled", leftAt };
        values = answer;
      }
      await client.perform(hop, key, values);
      leftAt = hop.to;
    }
    const [status] = await client.transitions(key);
    return laneOfJiraStatus(status) === target ? { kind: "moved", to: status } : { kind: "stopped", at: status, target };
  } catch (e) {
    return { kind: "failed", message: e.message ?? "Jira refused the move.", leftAt };
  }
}
