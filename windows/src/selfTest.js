import { app } from "electron";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// `PRMASTER_SELFTEST=1 electron .`: loads the real windows against real data and
// reports what they painted, since neither the tray nor a window can be inspected
// from outside. Read-only: it loads, it never writes to GitHub.
// `PRMASTER_SELFTEST_DIFF=1` also opens the diff of the first review request.
export async function runSelfTest({ win, tray, diffs, getState, viewState, settingsWindow, board, markQuitting }) {
  if (win.webContents.isLoading()) await new Promise((r) => win.webContents.once("did-finish-load", r));
  win.webContents.send("state", viewState());
  await sleep(500); // let the renderer paint
  const dom = await win.webContents.executeJavaScript(
    `({ title: document.getElementById("title").textContent,
        rows: document.querySelectorAll(".row").length,
        shipments: document.querySelectorAll(".row[class*=ship-]").length,
        reviews: document.querySelectorAll(".row[class*=review-]").length,
        chips: [...document.querySelectorAll(".chip")].map((c) => c.textContent).join(" "),
        notes: [...document.querySelectorAll(".empty")].map((c) => c.textContent).join(" | "),
        buttons: [...document.querySelectorAll(".row button")].map((b) => b.textContent).join(","),
        first: document.querySelector(".row")?.innerText })`,
  );
  console.log(JSON.stringify({ tray: !tray.isDestroyed(), error: getState().error, dom }));

  const settingsWin = settingsWindow.open();
  await sleep(1500);
  console.log(JSON.stringify({ settings: await settingsWin.webContents.executeJavaScript(
    `({ sections: [...document.querySelectorAll("h2")].map((h) => h.textContent),
        controls: document.querySelectorAll("input, select, textarea").length,
        teams: document.body.innerText.includes("waiting") })`,
  ) }));

  // The Board tab, and GitHub project discovery (read-only; fails plainly without the project scope).
  await board.discoverProjects();
  await sleep(300);
  console.log(JSON.stringify({ board: await win.webContents.executeJavaScript(
    `(() => {
      document.getElementById("tab-board").click();
      return new Promise((resolve) => setTimeout(() => resolve({
        tabs: [...document.querySelectorAll("nav.tabs button")].map((b) => b.textContent),
        pane: document.getElementById("boardpane").innerText.slice(0, 160),
        toolbar: Boolean(document.getElementById("boardSearch")),
      }), 400));
    })()`,
  ), view: { configured: board.view().isConfigured, discoveryError: board.view().discoveryError?.slice(0, 160) ?? null, projects: board.view().projects.length } }));

  if (process.env.PRMASTER_SELFTEST_DIFF) console.log(JSON.stringify({ diff: await diffSelfTest(diffs, getState()) }));
  markQuitting();
  app.exit(0);
}

async function diffSelfTest(diffs, state) {
  const kind = state.reviews.length ? "review" : "own";
  const subject = (kind === "review" ? state.reviews : state.prs)[0];
  if (!subject) return "nothing to open";
  const entry = diffs.open(kind, subject.id);
  for (let i = 0; i < 120 && entry.phase === "loading"; i++) await sleep(500);
  await sleep(4000); // let highlighting finish and the renderer paint
  const dom = await entry.win.webContents.executeJavaScript(
    `({ title: document.getElementById("title").textContent,
        count: document.getElementById("count").textContent,
        banner: document.getElementById("banner").hidden ? null : document.getElementById("banner").textContent,
        sidebarFiles: document.querySelectorAll("nav .file").length,
        diffLines: document.querySelectorAll("tr.added, tr.removed").length,
        coloured: document.querySelectorAll("td.code span[style]").length,
        layout: document.getElementById("layout")?.value,
        merge: [document.getElementById("merge").hidden, document.getElementById("merge").disabled],
        approve: [document.getElementById("approve").hidden, document.getElementById("approve").disabled] })`,
  );
  return { kind, repo: subject.repo, number: subject.number, phase: entry.phase, error: entry.error, dom };
}
