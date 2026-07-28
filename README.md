# PRMaster

A macOS menu bar app that shows your open pull requests and tells you the moment
one is actually mergeable.

Each row shows the repo, number, title and a single glyph answering the only
question that matters: *can I merge this right now?* When a PR crosses into
ready, a notification offers **Open PR** or **Merge**.

## Install

```sh
curl -sL https://github.com/juancarlosllhL/PRMasterTray/releases/latest/download/PRMaster.app.zip -o /tmp/prmaster.zip \
  && ditto -x -k /tmp/prmaster.zip /tmp/prmaster \
  && rm -rf /Applications/PRMaster.app \
  && ditto /tmp/prmaster/PRMaster.app /Applications/PRMaster.app \
  && xattr -cr /Applications/PRMaster.app \
  && rm -rf /tmp/prmaster /tmp/prmaster.zip \
  && open /Applications/PRMaster.app
```

PRMaster is ad-hoc signed and **not notarized**, so Gatekeeper would otherwise
refuse it: `xattr -cr` is the step that makes it launch. `ditto` rather than
`unzip` because the bundle is signed, and unzip is a known way to extract one
that no longer validates.

Apple Silicon only — the release is built on an arm64 runner.

## Updating PRMaster

PRMaster checks for a new release every 30 minutes and offers **Update** at the
bottom of the popover. The gear holds **Check for Updates…** and shows the
version you are running.

One click downloads the release, checks it against the sha256 GitHub published
for that asset, and replaces the app in place before relaunching. A download
that fails the check is not installed, and if the swap itself fails the previous
version is put back rather than left missing.

**Notifications may need re-granting after an update.** macOS ties notification
permission to an app's code signature, and an ad-hoc signature is different on
every build — so an updated PRMaster can look like a different app and lose the
grant. Re-enable it under **System Settings → Notifications**. A Developer ID
would fix this properly; there isn't one.

## Requirements

- macOS 14+
- Swift 6 toolchain (Command Line Tools are enough — Xcode is not required)
- [`gh`](https://cli.github.com) installed and signed in:

```sh
brew install gh
gh auth login
```

PRMaster borrows the token from `gh` at each launch and holds it in memory only.
It stores no credential of its own — nothing on disk, nothing in the Keychain.

## Running it

```sh
make run
```

That builds, assembles `PRMaster.app`, ad-hoc signs it and launches it. The
signing step is not optional: `UNUserNotificationCenter` refuses to work in a
process with no bundle identifier, so a bare `swift build` binary cannot deliver
notifications at all.

To enable notifications, grant PRMaster permission under
**System Settings → Notifications**.

## Tests

```sh
make test
make test ARGS="--filter ReadinessTests"
```

Plain `swift test` will fail. Swift Testing ships with the Command Line Tools but
is not on SPM's search path there, and `Testing.framework` loads
`lib_TestingInterop.dylib` from a different directory again. `make test` wires up
both, deriving the paths from `xcode-select -p` so installing Xcode later does not
break it.

## Releasing

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`
2. Commit it, then tag and push:

```sh
git tag v0.2.0
git push origin main --tags
```

The tag is the trigger. GitHub Actions checks the tag against `Info.plist`, runs
the tests, builds the bundle and attaches `PRMaster.app.zip` to a new release.

A tag that disagrees with `Info.plist` fails the workflow before anything is
published, because the app compares release tags against its own version — a
mismatch would either offer an update the user already has, forever, or never
offer one at all. `make verify-version TAG=v0.2.0` is the same check locally.

The workflow also fails if the published asset carries no sha256 digest: the
updater refuses to install without one, so a release lacking it would not be
installable.

`make dist` builds the same zip locally, in `dist/`.

## How readiness is decided

`mergeStateStatus` is the authority, not `reviewDecision`. A PR can report no
required review and `mergeable: MERGEABLE` while branch protection still blocks
the merge, so a review-based rule would call it ready when GitHub would refuse.

| Glyph | State | Meaning |
|---|---|---|
| green check | `ready` | `CLEAN`, `UNSTABLE` or `HAS_HOOKS` |
| yellow down-arrow | `behind` | head is behind base |
| blue eye | `blocked` | branch protection, usually pending review |
| yellow clock | `checksPending` | checks running, or GitHub still computing |
| red cross | `checksFailing` | a required check failed |
| orange triangle | `conflicted` | merge conflicts |
| grey pencil | `draft` | dimmed, never notified about |

`UNKNOWN` maps to *pending*, never *ready*: GitHub returns it while recomputing
mergeability after a push, so treating it as ready would fire a notification on
every push.

## Merging

**Merge** always shows a confirmation first, then squash-merges with
`expectedHeadOid` pinned to the commit you were shown. If anything landed since,
GitHub refuses rather than merging code you never saw, and the refusal is shown
in GitHub's own words.

## Keeping branches up to date

A PR that reports `BEHIND` is brought up to date automatically: PRMaster merges
the base branch into it, exactly as GitHub's own **Update branch** button does.
No confirmation — this is the one thing the app does on its own initiative.

**Auto-update behind branches**, under the gear in the top right of the popover,
turns it off. The setting survives a relaunch and is on by default.

Not to be confused with **Check for Updates…** in the same menu, which is about
new versions of PRMaster itself. This setting only ever touches pull request
branches.

Constraints worth knowing:

- Only PRs whose readiness is `behind` qualify. Drafts, conflicts and failing or
  running checks all outrank merge state, so none of them are ever touched.
- `BEHIND` is only reported where branch protection requires an up-to-date
  branch. Elsewhere a stale PR reports `CLEAN` and is left alone, because
  nothing is blocking it.
- Each attempt is keyed to the head commit. A refused update is never retried
  while the branch is unchanged, so a conflict cannot become a loop.
- `expectedHeadOid` is pinned here too, and the update never runs at all while
  any debug hook is active.
- Titles are shown with `:gitmoji:` shortcodes rendered as emoji. Codes outside
  the gitmoji set are left as written.

## Debug hooks

The interesting states normally need a real reviewer or a real outage. These make
them reachable on demand. All of them fake only *fetching* — merging always goes
to the real API.

| Variable | Effect |
|---|---|
| `PRMASTER_FIXTURE=path.json` | serve PRs from a search-response JSON file |
| `PRMASTER_FAKE_ERROR=ghNotFound\|notAuthenticated\|network` | force a failure state |
| `PRMASTER_FAIL_AFTER=n` | succeed `n` times, then fail — shows the stale banner |
| `PRMASTER_DEMO_MERGE=confirm\|fail` | open the merge confirm sheet or failure alert |
| `PRMASTER_AUTO_OPEN=1` | open the popover at launch |

```sh
open -a .build/PRMaster.app --env PRMASTER_FIXTURE="$PWD/Fixtures/demo.json"
```

Plain `open` drops the environment, hence `--env`. Running the bundle's binary
directly works too, and anchors correctly:

```sh
PRMASTER_FIXTURE="$PWD/Fixtures/demo.json" .build/PRMaster.app/Contents/MacOS/PRMaster
```

## Layout

```
Sources/PRMasterCore/   pure, fully tested, no AppKit
Sources/PRMaster/       AppKit + SwiftUI shell
Tests/                  174 tests, no network, no gh required
.github/workflows/      tag-driven release
```

## Scope

Deliberately not included: multiple GitHub accounts (uses whichever `gh` account
is active), PRs awaiting your review, launch at login, and merge methods other
than squash.
