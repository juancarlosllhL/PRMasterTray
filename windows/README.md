# PR Master for Windows

The Windows build of PR Master: a system-tray app that lists your open pull
requests and says which ones GitHub would merge right now. It is a port of the
macOS app in the parent directory (Electron, plain JavaScript, no build step for
the app itself), and keeps its decisions: the same readiness rules, the same
queries, the same safeguards around the things that write.

## What it does

The same as the macOS app, with the platform differences listed below:

- **Pull requests** with a readiness state per row, a toast when one becomes
  mergeable, **Merge** (squash, after a confirmation) on a ready one, **Close** on
  ones you forgot, and branches brought up to date for you if you switch that on.
- **Recently merged**: pipeline status, the version a merge went out in, and
  **stg** / **prod** chips read from the deployments repositories.
- **Review requests** of the teams you belong to.
- **Review window**: the whole diff, unified or split, coloured with Shiki, with
  GitHub's own **Viewed** checkbox, tests/generated/other files set aside, find,
  and **Approve** or **Merge** pinned to the commit you read. **Score** marks how
  closely each block needs reviewing.
- **Board**: what is assigned to you in Jira and on the GitHub projects you
  switch on, as a list or as columns; drag a card, or right-click it, to move it.
- **Settings** for lists, filters, teams, diff viewer, Board and Score, with a
  light or dark theme.

## Requirements

- Windows 10 or 11, x64.
- The [GitHub CLI](https://cli.github.com), signed in: `gh auth login`. The app
  stores no GitHub credential of its own; it asks `gh` for a token at each poll.
  Scopes: `repo` always; `read:org` for review requests and teams; `project` for
  GitHub projects on the Board (`gh auth refresh -s project`).
- If your shell sets `GH_TOKEN`, that token is what `gh` hands out, scopes and all.
  To use the stored login instead, remove the variable and run
  `gh auth login -h github.com -s read:org`.

## Install

Download `PRMaster-Setup.exe` from the latest `windows-v…` release and run it. It
installs per user (no administrator rights) and starts the app. The installer is
not code-signed, so SmartScreen may ask you to confirm. The in-app updater checks
the releases every 30 minutes and installs a newer one after verifying the sha256
that GitHub publishes for it.

New tray icons are hidden by Windows 11: pull the icon out of the `^` overflow
onto the taskbar to keep it visible.

## Differences from the macOS app

- Notifications open the window; Windows toasts from this app carry no **Merge**
  action button.
- No popover or docked-panel modes, popover background, monochrome palette or
  "keep windows clear": the list is an ordinary window that hides to the tray.
- **Open at login** works in the installed app only.
- The Jira and OpenRouter credentials are encrypted with Windows' own per-user
  protection (DPAPI) instead of the Keychain.
- Two behaviours go beyond the macOS app, on purpose: a YAML alias such as
  `repository: *name` in a CircleCI config is resolved when discovering which
  deployments folders a service ships into, and a promoted version written with a
  `v` prefix matches its release tag.
- **Keep branches up to date** is off until you turn it on, because it pushes
  commits to your branches.
- The debug fixtures (`PRMASTER_FIXTURE`) are not ported.
- Review requests are asked of GitHub one search at a time rather than in one
  document: on a large account the combined request outran GitHub's time limit.

## Status

Everything that talks to GitHub for reading has been run against a real account.
These have **only** been exercised against simulated responses, not the real
services: Jira (sign-in, issues, moves), Score (OpenRouter), and every write to
GitHub (merge, close, approve, update branch, Viewed, project Status). The
installer and the in-app update install have been built but not run.

## Developing

```sh
pnpm install
pnpm test          # 440+ tests, no network
pnpm start         # runs the app (needs `gh auth login`)
pnpm run dist      # builds dist/PRMaster-Setup.exe
```

`PRMASTER_SELFTEST=1 pnpm start` loads the real windows against real data, prints
what they painted and exits (read-only). Add `PRMASTER_SELFTEST_DIFF=1` to open a
review window as well.

Layout: `src/core` is the app's logic and speaks to nothing but GitHub, Jira and
OpenRouter over HTTP (so it is what the tests cover); `src/*.js` are the Electron
windows and processes; `src/renderer`, `src/diff`, `src/settings` and
`src/whatsnew` are the pages. `resources/shiki.js` is the same bundle the macOS app
runs, and runs here in a worker thread.

## Releasing

Bump `version` in `package.json`, add its section to `CHANGELOG.md`, and push a tag
`windows-v<version>`. The `Release (Windows)` workflow checks the tag against the
version, runs the tests, builds the installer and publishes it with a digest.
