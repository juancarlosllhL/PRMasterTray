# Changelog

What each release changed, newest first. The app shows the entries you missed
the first time it runs after an update, so keep the lines short and written for
whoever has to read them in a small window.

## 0.14.0 — 2026-09-28

- Review replaces Merge and Approve on the rows. It opens a window with the pull request's whole diff, a file list down the side.
- Switch between unified and split, and tick Viewed on a file the way you would on GitHub. Viewed files fold away.
- Code is coloured for Swift, Go, TypeScript and JavaScript, C#, Python, JSON, YAML and shell.
- Long lines wrap inside the window. Pick the diff's font, its size and whether ligatures are drawn: Settings, Diff Viewer.
- Merge and Approve now live at the bottom of that window, and act on exactly the commit you read. If someone pushes meanwhile, the window says so and offers a reload.

## 0.13.0 — 2026-09-28

- Issues under review get their own Reviewing section and board column, between In progress and Testing.
- Jira issues can be moved between To do, In progress, Reviewing, Testing and Done: drag a card to another column on the board, or right-click an issue in either layout and pick where it goes.
- When Jira's workflow has steps in between, such as In Progress on the way from To Do to Reviewing, the app walks through them for you.
- The card lands in its new column at once. If Jira refuses, it goes back and a banner says where it stopped and why.
- When a step needs fields, such as a bug going from Reviewing to Testing, a short form asks for them first: Changelog status, Changelog and Remark. Remark gets "PM:" added if you leave it out.
- Moves never cancel an issue or park it.
- Right-click any pull request or Jira issue, in either tab, to copy its link or its ID. An issue's ID is its key, a pull request's is repository#number.

## 0.12.0 — 2026-09-22

![The Jira tab as a board, a column per group](whats-new-0.12.0.png)

- The Jira tab can be drawn as a board, a column per group, with each issue as a card. It is off until you switch it on: Settings, Jira, Layout, Board.
- The popover widens to fit the columns while the board is open, and narrows again when you leave it.
- Done keeps its own column unless its window is off, in which case the column goes rather than sit permanently empty.
- Leaving Layout on List keeps the Jira tab exactly as it was.

## 0.11.1 — 2026-09-18

- The remark posted with an approval draws from twice as many lines, so the same joke stops coming back.
- Every kind of pull request now has several remarks to choose from, not one. A single-file change, a revert and a dependency bump each had only one before.

## 0.11.0 — 2026-09-14

- Jira issues in testing now have a section of their own, below In progress.
- A filter field at the top of the Jira pane narrows every section at once, on issue key or summary.
- Jira rows show the issue type in its own colour, the priority as an arrow, and how long ago the issue was raised.
- Jira lists are ordered by priority, then by the newest first.
- To do holds only New and To Do, so parked work is no longer offered as something to pick up.
- Epics are left out of the Jira pane entirely.
- The whole left edge of a Jira row now expands it, instead of an arrow you had to hit exactly.
- A title too long for its row shows in full when you hover it, and only then.
- Appearance settings can leave the emoji out of pull request titles.
- Merged rows no longer sit on "building" after they have shipped.
- The Keychain stops asking for your login password on every launch.
- Signing in to Jira takes effect without restarting the app.
- Settings lost the paragraphs it did not need.
