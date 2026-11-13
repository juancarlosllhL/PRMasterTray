# Changelog

What each release changed, newest first. The app shows the entries you missed the
first time it runs after an update, so keep the lines short and written for
whoever has to read them in a small window.

## 0.1.0 — 2026-10-30

- PR Master now runs on Windows, from the system tray. The window lists your open pull requests, says which ones GitHub would merge right now, and notifies you when one becomes mergeable.
- Merge a ready pull request from its row, close ones you forgot, and bring behind branches up to date automatically if you switch that on in Settings.
- Recently merged shows what became of each merge: its pipeline, the version it went out in, and whether stg and prod carry it.
- Waiting on your teams lists the review requests of the teams you belong to. This needs the read:org scope on your GitHub token.
- Review opens a window with the whole diff: unified or split, coloured with Shiki, with GitHub's own Viewed checkbox, files set aside, find, and Approve or Merge pinned to the commit you read.
- Score gives each block of changed lines a stripe for how closely to review it, using an OpenRouter key you add in Settings.
- Board shows what is assigned to you in Jira and on the GitHub projects you switch on, as a list or as columns. Drag a card, or right-click it, to move it.
- Settings covers the lists, filters, teams, diff viewer, Board and Score, with a light or dark theme.
