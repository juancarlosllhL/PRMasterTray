# Development

Everything the [README](../README.md) leaves out: how to build it, how to reach
the states it shows, and how a release is cut.

## Requirements

- macOS 14+
- Swift 6 toolchain — the Command Line Tools are enough, Xcode is not required
- [`gh`](https://cli.github.com) installed and signed in

## Running it

```sh
make run
```

That builds, assembles `PRMaster.app`, ad-hoc signs it and launches it. The
signing step is not optional: `UNUserNotificationCenter` refuses to work in a
process with no bundle identifier, so a bare `swift build` binary cannot deliver
notifications at all.

`make install` puts it in `/Applications` instead. Worth doing beyond
convenience — macOS treats an app living there more like a real app than one run
out of `.build`, which is the leading suspect whenever notification
authorization is refused.

## Tests

```sh
make test
make test ARGS="--filter ReadinessTests"
```

Plain `swift test` will fail. Swift Testing ships with the Command Line Tools but
is not on SPM's search path there, and `Testing.framework` loads
`lib_TestingInterop.dylib` from a different directory again. `make test` wires up
both, deriving the paths from `xcode-select -p` so installing Xcode later does
not break it.

## Layout

```
Sources/PRMasterCore/   pure, fully tested, no AppKit
Sources/PRMaster/       AppKit + SwiftUI shell
Tests/                  174 tests, no network, no gh required
.github/workflows/      tag-driven release
```

The name splits three ways, deliberately:

- **PR Master Tray** is the display name — `CFBundleName`, `CFBundleDisplayName`,
  and the two strings in the gear menu.
- **PRMaster** is the bundle, the executable, `com.jcll.PRMaster`, and
  `PRMaster.app.zip`. The installer and the in-app updater both look that asset
  up by exact name, and macOS ties the notification permission to the bundle
  identifier, so renaming any of it breaks existing installs.
- **PRMasterTray** is the repository.

## How readiness is decided

In the [README](../README.md#the-list), with the mapping table.
`Readiness.evaluate` is the implementation; `ReadinessTests` covers every branch
of it.

## Debug hooks

The interesting states normally need a real reviewer or a real outage. These make
them reachable on demand, and every screenshot in the README was taken through
them. All of them fake only *fetching* — merging always goes to the real API.

| Variable | Effect |
|---|---|
| `PRMASTER_FIXTURE=path.json` | serve PRs from a search-response JSON file |
| `PRMASTER_FAKE_ERROR=ghNotFound\|notAuthenticated\|network` | force a failure state |
| `PRMASTER_FAIL_AFTER=n` | succeed `n` times, then fail — shows the stale banner |
| `PRMASTER_DEMO_MERGE=confirm\|fail` | open the merge confirm sheet or failure alert |
| `PRMASTER_AUTO_OPEN=1` | open the popover at launch |

Setting any override refuses merges outright, hides the row's **Merge** button
and drops the **Merge** action from notifications: a fixture is routinely
captured from a live response, so its rows can carry real node IDs and real head
oids. `PRMASTER_DEMO_MERGE` is the exception. It swaps in a merger that accepts
and does nothing, so under it the affordances are safe — and present, which is
the point of the hook. Any value other than `confirm` or `fail` gives you that
without opening a dialog.

```sh
open -a .build/PRMaster.app --env PRMASTER_FIXTURE="$PWD/Fixtures/demo.json"
```

Plain `open` drops the environment, hence `--env`. Running the bundle's binary
directly works too, and anchors correctly:

```sh
PRMASTER_FIXTURE="$PWD/Fixtures/demo.json" .build/PRMaster.app/Contents/MacOS/PRMaster
```

Two things to know when reproducing the screenshots. A notification is posted
once per PR id and then never again, so re-shooting one needs
`defaults delete com.jcll.PRMaster notifiedPRIDs` *and* a fixture id macOS has
not seen — re-adding a request with a delivered identifier updates it silently
instead of showing a new banner. And the popover only offers the auto-update
toggle when no override is active, because the store has no updater in that
state and a switch for a feature that cannot run would be a lie.

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
