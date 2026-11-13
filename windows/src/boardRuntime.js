// The Board at run time: Jira and GitHub Projects, their sign-in, polling and
// moves, and the view the window draws. Free of Electron so it can be tested with
// the clients injected; main.js wires it to windows and timers.
import { boardView } from "./core/boardView.js";
import { cardIdFrom } from "./core/board.js";
import { BOARD_LANES } from "./core/jira.js";
import { JiraSource, ProjectSource } from "./core/boardSources.js";
import { PullRequestFilter } from "./core/filter.js";
import { createJiraClient } from "./core/jiraApi.js";
import { restoreJira, signInToJira, signOutOfJira } from "./core/jiraSession.js";
import { fetchProjectItems, fetchProjects, fetchPullRequestsForIssueKeys, fetchViewerLogin, setProjectStatus } from "./core/projects.js";

const LANE_IDS = BOARD_LANES.map((l) => l.id);

const defaultJiraClients = (credentials, { getToken, fetchImpl }) => {
  const client = createJiraClient({ credentials, fetchImpl });
  return {
    issues: { assignedIssues: (days) => client.assignedIssues(days) },
    links: { fetch: (keys) => fetchPullRequestsForIssueKeys({ token: getToken, fetchImpl, keys }) },
    mover: client,
  };
};

const defaultGithubClients = ({ getToken, fetchImpl }) => {
  let login = null; // the viewer's login is asked for once, not once per board per poll
  return {
    client: {
      fetchProjects: () => fetchProjects({ token: getToken, fetchImpl }),
      fetchItems: async (projectID) => fetchProjectItems({ token: getToken, fetchImpl, projectID, login: (login ??= await fetchViewerLogin({ token: getToken, fetchImpl })) }),
    },
    mover: { setStatus: (a) => setProjectStatus({ token: getToken, fetchImpl, ...a }) },
  };
};

export function createBoardRuntime({
  settings,
  secrets,
  getToken,
  notify = () => {},
  now = () => new Date(),
  fetchImpl = fetch,
  jiraClients = defaultJiraClients,
  githubClients = defaultGithubClients,
  signIn = signInToJira,
}) {
  let query = ""; // deliberately not persisted: a filter still in force on the next launch, with nothing on screen to say so, reads as a board that has broken
  let jiraInfo = null; // { name, baseURL, email } for the Settings screen
  let polling = false;
  const timers = new Set();

  const jira = new JiraSource({ now, windowDays: settings.get("jiraWindowDays") });
  const github = githubClients({ getToken, fetchImpl });
  const projects = new ProjectSource({
    client: github.client,
    mover: github.mover,
    known: settings.get("knownProjects"),
    selection: settings.get("projectSelection"),
    laneMap: settings.get("projectLaneMap"),
    persist: (what, value) => settings.set({ projects: "knownProjects", selection: "projectSelection", laneMap: "projectLaneMap" }[what], value),
    now,
    windowDays: settings.get("jiraWindowDays"),
  });
  jira.onChange = notify;
  projects.onChange = notify;

  function connectJira(credentials) {
    if (!credentials) return jira.connect(null);
    const clients = jiraClients(credentials, { getToken, fetchImpl });
    jira.connect(clients.issues, clients.links, clients.mover);
  }

  const filter = () => new PullRequestFilter({ hiddenOrganizations: settings.get("hiddenOrganizations"), showPrivateRepositories: settings.get("showPrivateRepositories") });

  // What the Settings screen needs: who is signed in to Jira, and the GitHub boards with their columns.
  function settingsView() {
    const credentials = restoreJira({ store: secrets });
    return {
      jira: { signedIn: jira.isConfigured, name: jiraInfo?.name ?? null, baseURL: credentials?.baseURL ?? null, email: credentials?.email ?? null },
      discoveryError: projects.discoveryError?.message ?? null,
      projects: projects.projects.map((p) => ({
        id: p.id,
        title: p.title,
        owner: p.owner,
        hasStatus: Boolean(p.statusFieldID),
        shown: projects.selection.has(p.id),
        options: p.options.map((o) => ({ id: o.id, name: o.name, choice: projects.laneMap.choice(o.id, o.name, p.id) })),
        noStatusChoice: projects.laneMap.choice(null, null, p.id),
      })),
    };
  }

  function view() {
    const days = settings.get("jiraWindowDays");
    const credentials = restoreJira({ store: secrets });
    return {
      ...boardView({ jira, projects, windowDays: days, query, siteURL: credentials?.baseURL ?? null, now: now(), filter: filter() }),
      query,
      layout: settings.get("boardLayout"),
      windowDays: days,
      ...settingsView(),
    };
  }

  return {
    view,
    settingsView,

    // Picks up a saved sign-in. Polling is separate, so a test can drive refreshes itself.
    async init() {
      connectJira(restoreJira({ store: secrets }));
    },

    setQuery(value) {
      query = String(value);
      notify();
    },

    async refreshAll() {
      await Promise.all([jira.refresh(), projects.refresh()]);
    },

    // ---- Jira sign-in -------------------------------------------------------

    async signInToJira(input) {
      const out = await signIn({ input, store: secrets, fetchImpl });
      jiraInfo = out;
      connectJira(restoreJira({ store: secrets }));
      await jira.refresh();
      notify();
      return out;
    },

    signOutOfJira() {
      signOutOfJira({ store: secrets });
      jiraInfo = null;
      connectJira(null);
      notify();
    },

    // ---- GitHub projects ----------------------------------------------------

    async discoverProjects() {
      await projects.discover();
    },

    setProjectShown: (id, shown) => projects.setShown(id, shown),

    // `choice` is a lane id, or "hidden". An empty option id stands for "no Status".
    setProjectChoice(projectID, optionID, choice) {
      projects.setChoice(choice, optionID, projectID);
      notify();
    },

    // ---- Moving -------------------------------------------------------------

    // What arrives from a drop is checked: a string from another app moves nothing.
    async move(rawCardId, lane) {
      const id = cardIdFrom(String(rawCardId));
      if (!id || !LANE_IDS.includes(lane)) return;
      if (id.kind === "jira") await jira.move(id.key, lane);
      else if (id.kind === "project") await projects.move(id.item, lane);
      // Together: Jira may sit on its form while GitHub has already moved the card.
      else await Promise.all([projects.move(id.item, lane), jira.move(id.key, lane)]);
    },

    submitFields: (values) => jira.submitFields(values),
    cancelFields: () => jira.cancelFields(),

    dismissMoveFailures() {
      jira.dismissMoveFailure();
      projects.dismissMoveFailure();
      notify();
    },

    // A setting that changes what the sources ask for.
    async settingChanged(key) {
      if (key === "jiraWindowDays") {
        projects.windowDays = settings.get("jiraWindowDays");
        await jira.setWindow(settings.get("jiraWindowDays"));
      }
      notify();
    },

    // ---- Polling ------------------------------------------------------------

    startPolling() {
      if (polling) return;
      polling = true;
      const loop = async (source) => {
        while (polling) {
          await source.refresh().catch(() => {});
          await new Promise((resolve) => {
            const timer = setTimeout(() => (timers.delete(timer), resolve()), source.pollIntervalMs);
            timers.add(timer);
          });
        }
      };
      loop(jira);
      projects.discover().finally(() => loop(projects));
    },

    stopPolling() {
      polling = false;
      for (const t of timers) clearTimeout(t);
      timers.clear();
    },
  };
}
