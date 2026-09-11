# Task: make updates visible and easy

Work this out in the repo `joost-heijden/Tickoala` (macOS menu bar app, Swift
Package Manager, no third-party dependencies). This task can be read on its own:
everything you need is below.

## Why

Anyone who installs the app follows the README: `git clone` → `./scripts/build-app.sh`
→ `cp -R build/Tickoala.app /Applications/`. That is a snapshot. Nothing later
checks whether a newer version exists, and the app doesn't even know which version
it is: `CFBundleShortVersionString` is hardcoded to `1.0` in
`scripts/build-app.sh`. There are no tags and no releases.

Goal: someone running the app notices that a new version exists, and can catch up
with a single command.

Deliberately **not** in scope: Sparkle, a Homebrew cask, notarization, and the app
downloading and replacing itself. The app is ad-hoc signed
(`codesign --sign -`); a zip downloaded from GitHub gets a quarantine flag and is
rejected by Gatekeeper as long as there is no Developer ID plus notarization.
Everyone builds their own, and this plan is built on that.

## Part 1 — `scripts/update.sh`

One command that updates and restarts. Follow the style of
`scripts/build-app.sh` (`set -euo pipefail`,
`root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`, messages in English).

Steps, in this order:

1. Refuse if this is not a git clone (someone downloaded a zip), with an
   explanation of what to do instead.
2. Refuse if the working tree is dirty (`git status --porcelain` not empty).
   Never silently build over someone else's work.
3. `git pull --ff-only`. No rebase, no merge: if it can't move forward, the user
   has to see that themselves.
4. Remember the version before and after the pull
   (`git describe --tags --always`) and report at the end which step was taken. If
   nothing changed, say so and stop — don't rebuild needlessly.
5. `"$root/scripts/build-app.sh" release`.
6. Stop a running app: `osascript -e 'tell application "Tickoala" to quit'`, then
   wait a few seconds for the process to go, with `pkill -x Tickoala` as a last
   resort.
7. `rm -rf "$target/Tickoala.app"` and `cp -R build/Tickoala.app "$target"/`. Note:
   `cp -R` must preserve the symlink at the top of the bundle as a symlink (it
   does on macOS); see part 2 of `build-app.sh` for why it is there.
8. `open "$target/Tickoala.app"`.

Destination configurable via `TICKOALA_APP_DIR`, with `/Applications` as the default.

## Part 2 — real version numbers

Right now the app doesn't know what it is, so it can't compare anything either.

- Version tags in the form `v1.1.0`. Put `v1.1.0` on the current `main` right away;
  that is the first version with the new icons.
- `scripts/build-app.sh` derives the version from git:
  `CFBundleShortVersionString` from `git describe --tags --abbrev=0` without the
  `v`, and `CFBundleVersion` from `git rev-list --count HEAD`.
- Without tags (fresh clone, loose zip) the build must **not** break: fall back to
  `0.0.0` and let the check from part 3 keep quiet.
- The Info.plist is written with a quoted heredoc (`<<'PLIST'`), so nothing is
  expanded now. Keep it that way and replace two placeholders (for example
  `__VERSION__` and `__BUILD__`) with `sed` afterwards. A heredoc *without* quotes
  works today too, but breaks as soon as someone ever puts a `$` in that plist.

## Part 3 — notice in the app

### Comparing (in `TickoalaCore`, because that is testable)

New file `Sources/TickoalaCore/VersionCheck.swift`:

- A `Version` value that reads `"1.2.3"` and `"v1.2.3"` and can be compared.
  Missing parts count as zero, so `1.2` and `1.2.0` are equal.
- Unreadable input yields `nil`, no crash and no guess.
- A function that, from a list of available versions, returns whether there is a
  newer one than the current — and `nil` for an equal or older version, and always
  `nil` when the current version is `0.0.0` (development build or no tags).

No networking in this file. That is exactly why it lives here.

### Fetching (in `TickoalaApp`)

New file `Sources/TickoalaApp/UpdateChecker.swift`, an `ObservableObject` with
`@Published private(set) var availableVersion: String?`.

- `https://api.github.com/repos/joost-heijden/Tickoala/tags`, field `name`. A 404
  means "no tags yet" and is not an error.
- GitHub requires a `User-Agent` header; without one you get a 403. Use
  `Tickoala/<version>`.
- At most one check per 24 hours. The moment of the last check in `UserDefaults`.
  Check at app start; after that nothing extra is needed: `AppModel` already has a
  timer that ticks every second.
- Ten-second timeout, no retries. If it fails, visibly nothing happens — a menu bar
  app should not nag about a flaky network.
- Can be turned off with a key in `UserDefaults`. No setting in the `settings`
  table: that is `Int`-based, is shared with the adapter command, and this is only
  about the app.

### Showing (in `MenuContent.swift`)

Above the last block with "Quit Tickoala":

- `Text("Version X available")` if there is something.
- A button that opens the tag page with `NSWorkspace.shared.open`.
- A button to turn the check off.
- Show nothing as long as there is no newer version. No "you're up to date" line,
  no progress, no error message.

## Part 4 — checks

The suite is its own program, not XCTest: `Sources/TickoalaChecks`, with
`Harness.suite` and `Harness.test`. Add `VersionChecks.swift` with a
`versionChecks()` and call it from `Sources/TickoalaChecks/main.swift`.

At least cover: `1.2.0` is newer than `1.1.9`; equal versions give nothing; the
leading `v` doesn't matter; `1.2` and `1.2.0` are equal; junk yields `nil`; and
`0.0.0` as the current version never reports an update. No networking in the checks.

## Part 5 — README

The README is English (the rest of the repo is English too; keep it that way). After
"Install", add an "Updating" section with `./scripts/update.sh`, and write down
honestly what the check does: one request per day to `api.github.com`, where GitHub
sees the IP address and the version in the `User-Agent`, nothing else is sent, and
how to turn it off. The README currently promises emphatically that nothing leaves
the Mac; that promise must stay true.

## Conventions in this repo

- Comments in English, and they explain *why* something is there, not what the line
  does. Look at how `WifiWatcher.swift` and `build-app.sh` do that.
- Commit messages in English, in full sentences, with the reason included.
- No dependencies. Only Foundation, AppKit and SwiftUI.
- Swift language mode v5, minimum macOS 13.
- `swift build -c release` and `swift run TickoalaChecks` must stay clean.

## Done when

1. `./scripts/update.sh` works from any directory, refuses cleanly on a dirty
   working tree, and produces a running app on the new version.
2. `/Applications/Tickoala.app/Contents/Info.plist` contains the real version number.
3. With a version tag higher than the installed version the notice appears in the
   menu; with an equal tag nothing appears.
4. `swift run TickoalaChecks` is green, including the new checks.
5. Without a network the app starts and works without delay or notice.

## Note at the start

The working tree currently contains changes from another thread in
`Sources/TickoalaApp/AppModel.swift`, `Sources/TickoalaApp/OverviewWindow.swift`,
`Sources/TickoalaCore/Store.swift` and
`Sources/TickoalaChecks/PersistenceChecks.swift`. Don't commit those along with
yours, and coordinate before touching `MenuContent.swift` or `AppModel.swift`.
