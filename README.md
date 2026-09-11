# Tickoala

**Automatic work-hours tracking for macOS, based on the Wi-Fi network you're on.**

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

Walk into a client's office, your Mac joins their Wi-Fi, and the timer starts.
Leave, and it stops. No buttons, no browser tab, no account, no server — just a
menu bar icon and a SQLite file on your own Mac.

Built for consultants and contractors who work at more than one client and keep
forgetting to start a timer.

```
Working  3:42
  Acme [Acme-Guest] — Working   project: 2401 — Data migration
  today 6:15 · week 28:30   (net; break today -0:30)
```

## Why

Most time trackers want an account, a subscription and your data. The ones that
don't still need you to remember to press start. Your Mac already knows where you
are — it's connected to the client's Wi-Fi. Tickoala just uses that.

- **Nothing leaves your Mac.** No account, no sync, no telemetry. The core
  features make no network access at all; the only request the app ever makes is
  the daily version check described under [Updating](#updating).
- **It never invents time.** If your Mac was asleep, the block is flagged for you
  to correct rather than silently guessed.
- **Your raw data stays raw.** Break deduction and totals are calculated on top of
  the recorded blocks, never by editing them.

## Features

- **Automatic start/stop** when you join or leave a client's Wi-Fi network
- **Multiple networks per client** — guest network, staff network, several
  offices; roaming between them doesn't split your work block
- **Multiple clients**, each with their own projects and settings
- **Hourly rate per client**, in euro or dollar, with the resulting amounts shown
  in the overview and the CSV export
- **Projects** with number and name, switchable from the menu bar mid-session
- **Automatic break deduction** per client — e.g. subtract 30 minutes on any day
  you worked 6 hours or more, with the duration and the threshold set separately
- **Short dropouts don't end your day** — a configurable grace period means a
  flaky access point won't close your block
- **Manual control** — pause, resume, stop, and correct or add blocks by hand
- **Day / week / month totals**, per project and per day
- **CSV export** for invoicing
- **First-run welcome screen** with a one-click toggle to launch at login
- **Full command-line interface** for everything the app does

## Requirements

- macOS 13 or later (developed and tested on macOS 26)
- Xcode Command Line Tools (`xcode-select --install`)
- No other dependencies — zero third-party packages

## Install

```bash
git clone https://github.com/joost-heijden/Tickoala.git
cd Tickoala
./scripts/build-app.sh
cp -R build/Tickoala.app /Applications/
open /Applications/Tickoala.app
```

Optionally put the CLI on your `PATH`:

```bash
ln -sf /Applications/Tickoala.app/Contents/Helpers/tickoala /usr/local/bin/tickoala
```

Tickoala can start itself at login: toggle it on the first-run welcome screen, or
add `Tickoala.app` under System Settings → General → Login Items.

## Updating

If you installed by cloning the repository, update with a single command:

```bash
./scripts/update.sh
```

It refuses to run when you have uncommitted changes, pulls the latest version
with `git pull --ff-only`, rebuilds the app, replaces the copy in `/Applications`
(override the destination with `TICKOALA_APP_DIR`), and restarts it. It builds
locally on purpose: a downloaded bundle is ad-hoc signed and would be rejected by
Gatekeeper.

The app also checks once a day whether a newer version exists, so the menu bar can
tell you when there is one. When a new version tag appears, the menu shows
**Version X available** with a link to that tag on GitHub; you don't have to do
anything. That check is the only network access Tickoala makes: one request per
day to
`https://api.github.com/repos/joost-heijden/Tickoala/tags`. GitHub sees your IP
address and the version string in the `User-Agent` header (`Tickoala/<version>`);
nothing else is sent — no identifier, no usage data, no time entries, no location.
Everything about it lives under **Updates** in the menu: the version you are
running, **Check now**, and **Stop checking for updates**. Turn it off
there, or with:

```bash
defaults write local.tickoala.app update-check-disabled -bool true
```

### Location Services

macOS only reveals the name of the Wi-Fi network to apps that have **Location
Services** permission. Tickoala asks for this on first launch. Without it macOS
returns `<redacted>`, which is indistinguishable from "no Wi-Fi", so the app
deliberately sends no signals at all rather than guessing — the menu bar tells you
and offers a button to fix it.

Your location is never requested, stored or transmitted. Only the network name is
read, and only to match it against the clients you configured.

> The app is ad-hoc signed locally, so macOS may ask again after you rebuild it.

## Getting started

```bash
# One client, one or more of their Wi-Fi networks
tickoala profile add --name "Acme" --context "Acme-Guest,Acme-Staff"

# Projects for that client
tickoala project add --profile "Acme" --number 2401 --name "Data migration"

# Optional: an hourly rate, used for the amounts in the overview and export
tickoala rate set --profile "Acme" --rate 87.50

# Optional: subtract 30 minutes on days of 6 hours or more
tickoala break set --profile "Acme" --minutes 30 --threshold 6:00
```

All of this can also be done from the menu bar: **Manage customers**, **Manage
projects…**, **Break settings…** and **Overview and corrections…**.

Not sure what a network is called? Connect to it — the menu bar shows the current
network and, if it isn't linked yet, offers to attach it to a client on the spot.

## How it works

```
Wi-Fi network changes
        ↓
watcher turns it into a start/stop signal
        ↓
tracker validates it, applies the active project, writes to SQLite
        ↓
menu bar shows status and elapsed time
```

The signal source is deliberately dumb: it only reports "joined X" or "left X".
All the judgement lives in the tracker, which is what makes the behaviour
predictable:

| Situation | Behaviour |
| --- | --- |
| Unknown network | nothing happens, just a log line |
| No project selected yet | no start; the menu bar asks you to pick one |
| Second start while already running | no second block |
| Repeated signal within the dedupe window | ignored (default 30s) |
| Leaving | stop is scheduled, final only after a grace period (default 90s) |
| Brief dropout within that period | the scheduled stop is cancelled, block continues |
| Roaming between two networks of one client | treated as a brief dropout |
| Leaving with no timer running | log line only; never an empty or negative block |
| Two client networks active at once | nothing is stopped automatically; you choose |
| Mac asleep or shut down | no events invented; a block running over 16h is marked `open` for correction |
| No Location Services permission | no signals at all; the menu bar asks for access |

A block always ends at the moment of the stop signal, not when the grace period
expired.

Because the source is just an event feed, it's replaceable. A CLI adapter is
included if you'd rather drive it from something else:

```bash
tickoala start --context "Acme-Guest"
tickoala stop  --context "Acme-Guest"
```

## Break deduction

Set per client: how much break to subtract, and from how many hours it applies.
Both are configured separately, and it's off by default.

- applies **per client per day**, not per block — pausing during the day doesn't
  cause it to be subtracted twice
- the threshold is **inclusive**: set to 6:00, a day of exactly 6 hours already has
  the break subtracted
- below the threshold nothing is subtracted
- never subtracts more than you actually worked, so a day can't go negative

This is a **calculation on top of your raw blocks**. Time entries are never
modified, so you can change or disable the rule at any time — including
retroactively. Totals, the menu bar and the export show net hours; the per-project
breakdown stays gross, because a break belongs to a day rather than to a project.

In the CSV export the deduction appears as its own row with a negative duration,
so the duration column adds up to your net hours. Use `--gross` to leave it out.

## Rates and amounts

Each client can have its own hourly rate and currency (euro or dollar). Set it
from the **Customers** window or from the command line:

```bash
tickoala rate set --profile "Acme" --rate 87.50
tickoala rate set --profile "Acme" --rate 100 --currency usd
tickoala rate list
```

The overview shows the amount for the selected period and the selected client
(net hours × rate, so the automatic break deduction is already applied). The CSV
export gains three columns, `hourly_rate`, `amount` and `currency`, next to every
block; the break row carries a negative amount so the `amount` column adds up to
the net total. Clients without a rate simply produce no amounts.

## Command line

```bash
tickoala status                 # also --json
tickoala report week            # or day / month, with --date and --profile
tickoala profile list           # clients, with their hourly rate
tickoala rate set --profile "Acme" --rate 87.50
tickoala entry list --period week
tickoala entry add --number 2401 --start "2026-09-10 09:00" --end "2026-09-10 17:00"
tickoala entry edit --id 12 --end "2026-09-10 16:30"
tickoala export --period month --out ~/Desktop/hours-september.csv
tickoala events                 # what was received and what happened with it
tickoala config list            # grace periods and thresholds
tickoala db                     # path to the database
```

`tickoala help` lists everything.

## Your data

Everything lives in
`~/Library/Application Support/Tickoala/tickoala.sqlite3` (override with the
`TICKOALA_DB` environment variable). It holds time entries, client names, network
names, projects, notes and a log of received events. No location data, and nothing
is ever uploaded — the only network request is the daily version check described
under [Updating](#updating).

Backing up is copying that one file.

## Development

```bash
swift build && .build/debug/TickoalaChecks
```

The suite covers start, stop, pause, resume, duplicate events, brief dropouts, two
clients at once, multiple networks per client, project linking, switching and
renumbering, unique project numbers, break deduction, restarting with an open
timer, day/week/month totals and CSV export, and runs the real CLI as a separate
process.

It runs as a plain executable rather than through `swift test`: XCTest and
swift-testing ship with full Xcode, not with the Command Line Tools, and this
project deliberately builds with just the CLT.

| Target | Purpose |
| --- | --- |
| `TickoalaCore` | data model, timer rules, totals, CSV export |
| `TickoalaApp` | menu bar app: Wi-Fi detection, overview, projects, corrections |
| `tickoala` | command-line interface and adapter |
| `TickoalaChecks` | the test suite |

## Known limitations

- Reading the Wi-Fi network name requires Location Services permission on macOS 14
  and later. There is no way around this for unsandboxed apps.
- The app is ad-hoc signed, so Gatekeeper warns on first launch and macOS may
  re-ask for permission after a rebuild.
- Time is attributed to whichever project is active when a block starts. Switching
  projects mid-session closes the block and opens a new one, so historical time
  stays with the right project.
- If you cross the break threshold while the timer is running, today's total drops
  by the break amount at that moment. Correct, but visible.

## The name

A koala barely moves and stays put for hours — which is exactly the behaviour
this thing measures. Add the tick of a clock and you get Tickoala.

## Contributing

Issues and pull requests are welcome. Please run `.build/debug/TickoalaChecks`
before submitting; the suite is fast and has no external dependencies.

## License

MIT — see [LICENSE](LICENSE).
