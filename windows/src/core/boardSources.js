// The two halves of the Board and what each remembers between polls: Jira and
// GitHub Projects. Each keeps its own fetch and moves; `board.js` composes them.
// Port of JiraStore.swift and ProjectStore.swift, with the timers left to the
// caller (`pollIntervalMs` says how long to wait).
import { moveIssue } from "./jiraApi.js";
import { laneOf } from "./jira.js";
import { LaneMap } from "./projects.js";
import { BOARD_LANES } from "./jira.js";

const INTERVALS_MS = [60_000, 120_000, 300_000];
const LINK_CHUNK = 20; // one document of aliased searches; larger would be refused
const titleOf = (lane) => BOARD_LANES.find((l) => l.id === lane).title;

// ---- Jira -------------------------------------------------------------------

export class JiraSource {
  // issues: { assignedIssues(windowDays) } | null until the user signs in (not a failure).
  // links:  { fetch(keys) } -> { key: [pull requests] }.
  // mover:  the transitions client | null for fixtures, so fake rows can never write to Jira.
  constructor({ issues = null, links = null, mover = null, now, windowDays }) {
    this.issueClient = issues;
    this.linkClient = links;
    this.mover = mover;
    this.now = now;
    this.windowDays = windowDays;
    this.issues = [];
    this.links = {};
    this.pendingLinkKeys = new Set();
    this.lastSuccessfulFetch = null;
    this.lastError = null;
    // Separate from lastError so a broken link lookup cannot raise the stale banner over a good list.
    this.lastLinkFailure = null;
    this.lastMoveFailure = null;
    this.moves = {}; // key -> { lane, settledAfter }
    this.fieldRequest = null; // a hop waiting for the user to fill its screen; one at a time
    this.fieldAnswer = null;
    this.onChange = () => {}; // told after every change, so the window can repaint mid-move
    this.isRefreshing = false;
    this.refreshGeneration = 0;
    this.session = 0; // bumped on every sign-in and sign-out, so a move from an older session lands nowhere
    this.consecutiveFailures = 0;
  }

  get isConfigured() {
    return this.issueClient !== null;
  }

  get canMove() {
    return this.mover !== null;
  }

  get pollIntervalMs() {
    return INTERVALS_MS[Math.min(this.consecutiveFailures, INTERVALS_MS.length - 1)];
  }

  // All four look like an issue with nothing under it unless kept apart: still
  // being looked up, looked up and failed, looked up and genuinely none, found.
  linkState(key) {
    if (this.pendingLinkKeys.has(key)) return "loading";
    const found = this.links[key];
    if (!found) return "unknown";
    return found.length === 0 ? "none" : "linked";
  }

  isMoving(key) {
    return this.moves[key] !== undefined && this.moves[key].settledAfter === null;
  }

  laneOf(issue) {
    return this.moves[issue.key]?.lane ?? laneOf(issue);
  }

  // ---- Refresh --------------------------------------------------------------

  async refresh() {
    if (this.isRefreshing || !this.issueClient) return;
    this.isRefreshing = true;
    try {
      const generation = ++this.refreshGeneration;
      let fetched;
      try {
        fetched = await this.issueClient.assignedIssues(this.windowDays);
      } catch (e) {
        this.consecutiveFailures++;
        this.lastError = e;
        this.onChange();
        return;
      }
      // An epic is a container for other people's work, never the thing a pull request is raised against.
      const listed = fetched.filter((i) => i.issueType.toLowerCase() !== "epic");
      this.issues = listed;
      // Only a fetch started after Jira confirmed a move is new enough to replace its override.
      this.moves = Object.fromEntries(Object.entries(this.moves).filter(([, m]) => m.settledAfter === null || m.settledAfter >= generation));
      this.lastError = null;
      this.lastSuccessfulFetch = this.now();
      this.consecutiveFailures = 0;
      this.onChange();
      await this.refreshLinks(listed);
    } finally {
      this.isRefreshing = false;
    }
  }

  async refreshLinks(issues) {
    if (!this.linkClient || issues.length === 0) return;
    const keys = issues.map((i) => i.key);
    const collected = {};
    let failure = null;
    this.pendingLinkKeys = new Set(keys.filter((k) => this.links[k] === undefined));
    this.onChange();
    try {
      for (let at = 0; at < keys.length; at += LINK_CHUNK) {
        const chunk = keys.slice(at, at + LINK_CHUNK);
        try {
          Object.assign(collected, await this.linkClient.fetch(chunk));
        } catch (e) {
          failure = e;
        }
        // Resolved either way: a failed chunk reads as unknown, not loading.
        for (const k of chunk) this.pendingLinkKeys.delete(k);
      }
    } finally {
      this.pendingLinkKeys = new Set();
    }
    // Only keys that answered are replaced, so a failed chunk leaves its issues
    // reading as unknown rather than as having none.
    this.links = { ...Object.fromEntries(Object.entries(this.links).filter(([k]) => keys.includes(k))), ...collected };
    this.lastLinkFailure = failure ? failure.message : null;
    this.onChange();
  }

  async setWindow(days) {
    if (days === this.windowDays) return;
    this.windowDays = days; // widening asks for issues the last search never requested
    await this.refresh();
  }

  // ---- Moving ---------------------------------------------------------------

  async move(key, lane) {
    const issue = this.issues.find((i) => i.key === key);
    if (!this.mover || this.isMoving(key) || !issue || this.laneOf(issue) === lane) return;

    this.lastMoveFailure = null;
    this.moves[key] = { lane, settledAfter: null };
    this.onChange();
    const startedIn = this.session;
    const outcome = await moveIssue({ client: this.mover, askFor: (request) => this.ask(request) }, key, lane);
    if (this.session !== startedIn) return;

    switch (outcome.kind) {
      case "moved":
        this.patch(key, outcome.to);
        this.moves[key].settledAfter = this.refreshGeneration;
        break;
      case "stopped":
        delete this.moves[key];
        this.lastMoveFailure = `${key} stopped at ${outcome.at.name}. Jira offers no way on from there to ${titleOf(outcome.target)}.`;
        break;
      case "cancelled":
        delete this.moves[key];
        if (outcome.leftAt) this.lastMoveFailure = `${key} was left at ${outcome.leftAt.name}. The form was closed before it went further.`;
        break;
      default: // failed
        delete this.moves[key];
        this.lastMoveFailure = outcome.leftAt ? `Couldn't move ${key} past ${outcome.leftAt.name} — ${outcome.message}` : `Couldn't move ${key} — ${outcome.message}`;
    }
    this.onChange();
    await this.refresh();
  }

  // A confirmed move is patched in so the board is right before the next poll.
  patch(key, status) {
    const at = this.issues.findIndex((i) => i.key === key);
    if (at < 0) return;
    const old = this.issues[at];
    this.issues[at] = {
      ...old,
      statusName: status.name,
      statusID: status.id,
      statusCategory: status.category,
      updatedAt: this.now().toISOString(),
      categoryChangedAt: status.category === old.statusCategory ? old.categoryChangedAt : this.now().toISOString(),
    };
  }

  // ---- The form a hop can open ---------------------------------------------

  ask(request) {
    if (this.fieldRequest) {
      this.lastMoveFailure = `Finish moving ${this.fieldRequest.key} first. Its form is still open.`;
      return Promise.resolve(null);
    }
    this.fieldRequest = request;
    this.onChange();
    return new Promise((resolve) => (this.fieldAnswer = resolve));
  }

  submitFields(values) {
    const request = this.fieldRequest;
    if (!request || request.fields.some((f) => f.problem(values[f.id] ?? ""))) return;
    this.answerForm(Object.fromEntries(request.fields.map((f) => [f.id, f.normalized(values[f.id] ?? "")])));
  }

  cancelFields() {
    this.answerForm(null);
  }

  answerForm(values) {
    const waiting = this.fieldAnswer;
    this.fieldAnswer = null;
    this.fieldRequest = null;
    waiting?.(values);
    this.onChange();
  }

  dismissMoveFailure() {
    this.lastMoveFailure = null;
  }

  // Signing in and out.
  connect(issues, links = null, mover = null) {
    this.issueClient = issues;
    this.linkClient = links;
    this.mover = mover;
    this.session++;
    this.answerForm(null);
    this.moves = {};
    this.lastError = null;
    this.lastLinkFailure = null;
    this.lastMoveFailure = null;
    this.consecutiveFailures = 0;
    if (!issues) {
      this.issues = [];
      this.links = {};
      this.pendingLinkKeys = new Set();
      this.lastSuccessfulFetch = null;
    }
    this.onChange();
  }
}

// ---- GitHub Projects --------------------------------------------------------

export class ProjectSource {
  // client: { fetchProjects(), fetchItems(projectID) }; mover: { setStatus({project, item, field, option}) } | null.
  // `persist(what, value)` is told when the known boards, the selection or the lane map change.
  constructor({ client = null, mover = null, known = [], selection = [], laneMap = {}, persist = () => {}, now, windowDays }) {
    this.client = client;
    this.mover = mover;
    this.projects = known;
    this.selection = new Set(selection);
    this.laneMap = new LaneMap(laneMap);
    this.persist = persist;
    this.now = now;
    this.windowDays = windowDays;
    this.items = [];
    this.moves = {};
    this.lastError = null;
    // Separate from lastError: a failed discovery leaves the known boards usable.
    this.discoveryError = null;
    this.lastSuccessfulFetch = null;
    this.lastMoveFailure = null;
    this.onChange = () => {};
    this.isRefreshing = false;
    this.refreshRequested = false;
    this.refreshGeneration = 0;
    this.consecutiveFailures = 0;
  }

  // Selected, and with a Status field: a board without one has no columns.
  get shownProjects() {
    return this.projects.filter((p) => this.selection.has(p.id) && p.statusFieldID);
  }

  get isConfigured() {
    return this.client !== null && this.shownProjects.length > 0;
  }

  get canMove() {
    return this.mover !== null;
  }

  get pollIntervalMs() {
    return INTERVALS_MS[Math.min(this.consecutiveFailures, INTERVALS_MS.length - 1)];
  }

  projectOf(item) {
    return this.projects.find((p) => p.id === item.projectID);
  }

  isMoving(itemID) {
    return this.moves[itemID] !== undefined && this.moves[itemID].settledAfter === null;
  }

  // The board's current name for the option, so a renamed column is guessed afresh.
  laneOf(item) {
    if (this.moves[item.id]) return this.moves[item.id].lane;
    const name = this.projectOf(item)?.options.find((o) => o.id === item.statusOptionID)?.name;
    return this.laneMap.lane(item.statusOptionID, name ?? item.statusName, item.projectID);
  }

  // ---- Settings -------------------------------------------------------------

  async setShown(projectID, shown) {
    if (shown) this.selection.add(projectID);
    else this.selection.delete(projectID);
    this.persist("selection", [...this.selection]);
    this.onChange();
    const shownIDs = new Set(this.shownProjects.map((p) => p.id));
    this.items = this.items.filter((i) => shownIDs.has(i.projectID));
    if (!this.isConfigured) {
      this.lastError = null;
      return;
    }
    await this.refresh();
  }

  // No refetch: this changes where items in hand are drawn, not which were asked for.
  setChoice(choice, optionID, projectID) {
    this.laneMap.set(choice, optionID, projectID);
    this.persist("laneMap", this.laneMap.toJSON());
  }

  // ---- Discovery ------------------------------------------------------------

  // A selected board GitHub stopped listing is kept: recent projects rotate out
  // of its answer, and a board you chose must not go with them.
  async discover() {
    if (!this.client) return;
    try {
      const found = await this.client.fetchProjects();
      const foundIDs = new Set(found.map((p) => p.id));
      const kept = this.projects.filter((p) => this.selection.has(p.id) && !foundIDs.has(p.id));
      this.projects = [...found, ...kept];
      this.persist("projects", this.projects);
      this.discoveryError = null;
    } catch (e) {
      this.discoveryError = e;
    }
    this.onChange();
  }

  // ---- Refresh --------------------------------------------------------------

  // A board that fails keeps its last items, so one broken board cannot empty the others' cards.
  async refresh() {
    if (!this.client) return;
    if (this.isRefreshing) {
      this.refreshRequested = true; // the running one goes round again rather than the new board waiting for the next poll
      return;
    }
    this.isRefreshing = true;
    try {
      do {
        this.refreshRequested = false;
        await this.refreshOnce();
      } while (this.refreshRequested);
    } finally {
      this.isRefreshing = false;
    }
  }

  async refreshOnce() {
    const asked = this.shownProjects;
    if (asked.length === 0) return;
    const generation = ++this.refreshGeneration;
    let collected = [];
    let failure = null;
    let answered = 0;
    for (const project of asked) {
      try {
        collected = collected.concat(await this.client.fetchItems(project.id));
        answered++;
      } catch (e) {
        failure = e;
        collected = collected.concat(this.items.filter((i) => i.projectID === project.id));
      }
    }
    const stillShown = new Set(this.shownProjects.map((p) => p.id));
    this.items = collected.filter((i) => stillShown.has(i.projectID));
    this.moves = Object.fromEntries(Object.entries(this.moves).filter(([, m]) => m.settledAfter === null || m.settledAfter >= generation));
    this.lastError = failure;
    if (answered > 0) this.lastSuccessfulFetch = this.now();
    this.consecutiveFailures = failure ? this.consecutiveFailures + 1 : 0;
    this.onChange();
  }

  // ---- Moving ---------------------------------------------------------------

  async move(itemID, lane) {
    const item = this.items.find((i) => i.id === itemID);
    const project = item && this.projectOf(item);
    if (!this.mover || this.isMoving(itemID) || !item || !project || this.laneOf(item) === lane) return;

    this.lastMoveFailure = null;
    const field = project.statusFieldID;
    const option = this.laneMap.target(lane, project);
    if (!field || !option) {
      this.lastMoveFailure = `${project.title} has no Status option in ${titleOf(lane)}. Map one under Settings, Board.`;
      return;
    }

    this.moves[itemID] = { lane, settledAfter: null };
    this.onChange();
    try {
      await this.mover.setStatus({ project: project.id, item: itemID, field, option: option.id });
      const at = this.items.findIndex((i) => i.id === itemID);
      // Keeps the item's own type: it may carry getters of its own.
      if (at >= 0) this.items[at] = Object.assign(Object.create(Object.getPrototypeOf(this.items[at])), this.items[at], { statusOptionID: option.id, statusName: option.name, statusChangedAt: this.now().toISOString() });
      this.moves[itemID].settledAfter = this.refreshGeneration;
    } catch (e) {
      delete this.moves[itemID];
      this.lastMoveFailure = `Couldn't move ${item.reference} — ${e.message}`;
    }
    this.onChange();
    await this.refresh();
  }

  dismissMoveFailure() {
    this.lastMoveFailure = null;
  }
}
