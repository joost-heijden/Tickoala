# Tickoala

<p align="center"><img src="design/AppIcon.png" width="128" alt="Tickoala"></p>

**Automatic work-hours tracking for macOS, based on the Wi-Fi network you're on or the place you're at.**

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

Walk into a client's office and the timer starts — because your Mac joins their
Wi-Fi, or because you are within the location you stored for them. Leave, and it
stops. No buttons, no browser tab, no account, no server — just a menu bar icon
and a SQLite file on your own Mac.

Built for consultants and contractors who work at more than one client and keep
forgetting to start a timer.

```
3:42
  Customer: Acme
  Working 3:42   project: 2401 — Data migration
  Today 6:15 · Week 28:30   (net; break today -0:30)
```

## Why

Most time trackers want an account, a subscription and your data. The ones that
don't still need you to remember to press start. Your Mac already knows where you
are — it's connected to the client's Wi-Fi, or you saved the spot once. Tickoala
just uses that.

- **Nothing leaves your Mac on its own.** No account, no sync, no telemetry. The
  core features make no network access at all; the only request the app makes by
  itself is the daily version check described under [Updating](#updating). An
  invoice is only ever emailed when you press send.
- **It never invents time.** If your Mac was asleep, the block is flagged for you
  to correct rather than silently guessed.
- **Your raw data stays raw.** Break deduction and totals are calculated on top of
  the recorded blocks, never by editing them.

## Features

- **Automatic start/stop** when you join or leave a client's network, or when you
  arrive at or leave a stored location
- **Detection by network or by location**, switchable in Settings; handy when you
  hop between networks at the same place
- **Falls back to the wired link** when Wi-Fi has no SSID — for example when the
  Mac shares its connection over Wi-Fi (Internet Sharing)
- **Multiple networks per client** — guest network, staff network, several
  offices; roaming between them doesn't split your work block
- **Switch prompt** — moving to another client while a block runs asks, as a
  notification with **Keep running** / **Start new block** buttons (or a pop-up
  when notifications are off), whether to keep the current project or start a new
  block
- **Undo and redo** with ⌘Z / ⇧⌘Z for every customer, project and block change,
  including deleting a customer or project, adding one, editing one, switching
  the active project and recording a break on a block
- **Delete a customer** with all their data, and get it back whole with ⌘Z
- **Multiple clients**, each with their own projects and settings
- **Hourly rate per client**, in euro or dollar, with the resulting amounts shown
  in the overview and the CSV export
- **Optional hour budget per project** with a burn-down, and a warning at 80% and
  100% — off by default, see [Project budgets](#project-budgets)
- **Billing rules per client** — round invoiced time to the quarter, round up,
  bill a minimum, and add evening or weekend surcharges — off by default, see
  [Billing rules](#billing-rules)
- **Travel time as its own line** — record a block as work, client travel or the
  commute, each with its own rate — see [Travel time](#travel-time)
- **Retainers** — a fixed amount per client (monthly, quarterly or yearly),
  optionally with an end date, put on the invoice automatically; a support
  contract with no tracked hours can be billed on its own with
  `tickoala retainer render-invoices` — see [Retainers](#retainers)
- **Holidays and vacation** — mark non-working days; the workday end no longer
  cuts them off — see [Holidays and vacation](#holidays-and-vacation)
- **UBL/Peppol export** — the invoice as a UBL 2.1 file for your bookkeeping —
  see [UBL/Peppol](#ublpeppol)
- **Expenses and mileage per client**, added to the invoice as their own lines,
  with an optional rate per kilometre — see [Expenses and mileage](#expenses-and-mileage)
- **Quarterly VAT return** per rate, built from the same hours and expenses the
  invoices show — see [VAT return](#vat-return)
- **Projects** with number and name, switchable from the menu bar mid-session
- **Tags** *(optional)* — free-form labels on a block ("meeting", "admin",
  "research") beside the client and project hierarchy, with a tag breakdown and a
  tag filter in the overview and a tags column in the CSV. Off by default under
  **Settings → Workday**; tags that arrive with an import are kept aside until you
  switch it on
- **Automatic break deduction** per client — e.g. subtract 30 minutes on any day
  you worked 6 hours or more, with the duration and the threshold set separately
- **Idle detection** — when you have been away from the Mac longer than a
  configured time, Tickoala asks on return whether to discard that stretch from
  the running block or keep it; the recorded start and end stay untouched, off by
  default under **Settings → Workday**
- **Dropouts don't end your day** — losing Wi-Fi keeps the current block running;
  it only closes once the day is over, so a flaky access point never splits your work
- **Manual control** — pause, resume, stop, and correct, add, duplicate or delete
  blocks by hand from the overview
- **Day / week / month totals**, per project and per day
- **Timeline with draggable bars** — the overview as bars instead of a table, so
  a correction is drag-and-drop
- **Charts** — the overview as a per-day chart (Swift Charts), showing hours or
  the invoiced amount, with one bar per day or stacked by project
- **Heatmap** — when you work: a weekday × hour grid shaded by the time that fell
  in each cell, so the shape of your week is visible at a glance
- **Shortcuts, Siri and a global hotkey** — start, stop and read today's hours
  without opening the menu bar; see [Shortcuts and the hotkey](#shortcuts-and-the-hotkey)
- **CSV export** for invoicing
- **Monthly invoice reminder** on the first weekday of the month
- **PDF invoices** with VAT, PO number, your logo and a running invoice number
- **Invoice history** — every invoice ever issued, with a click to jump to its
  month and buttons to rebuild the PDF, export the hours or send it again
- **Payment tracking** — mark an invoice paid, see the open amount at a glance,
  and get one quiet nudge a day when something is past its due date — the due
  date is fixed at issue so changing the payment term never moves old invoices
- **Credit notes** — reverse an invoice that went wrong with its own number and a
  reference to the original — see [Invoices](#invoices)
- **Email invoices** straight from the app over SMTP, with the PDF attached and
  optionally the hours CSV
- **Optional running timer** next to the menu bar icon — the running block's
  elapsed time, ticking every second, so the clock is readable without opening
  the menu; off by default under **Settings → General**
- **Optional running month revenue** next to the menu bar icon and per customer
  in the menu — a per-second total of what you have earned this month; off by
  default under **Settings → General**
- **First-run welcome screen** with a one-click toggle to launch at login
- **Import from Toggl Track, Harvest or Clockify** — bring your history over from
  a CSV export (menu: **Import time entries…**, or the CLI); clients and projects
  are created as needed and running the same file twice changes nothing
- **Goals** *(optional)* — a daily and/or weekly hour target across all clients,
  shown with your progress in the menu and the overview footer; off by default
  under **Settings → Workday**
- **Backup and restore** — a full copy of the database to one file, and back;
  the menu has **Data → Back up everything…** and **Restore from a backup…**,
  the CLI has `tickoala backup` and `tickoala restore`
- **Full command-line interface** for everything the app does

## Requirements

- macOS 13 or later (developed and tested on macOS 26)
- Xcode Command Line Tools (`xcode-select --install`)
- No other dependencies — zero third-party packages

## Install

### Homebrew

```bash
brew install --cask joost-heijden/tap/tickoala
```

Because Homebrew downloads the app itself, macOS does not quarantine it and the
"cannot be verified" warning below is skipped.

### Download the app

Grab `Tickoala-x.y.z.zip` from
[Releases](https://github.com/joost-heijden/Tickoala/releases), unzip it and drag
`Tickoala.app` into **Applications**. It is not notarized by Apple, so macOS
blocks the first launch; allow it once:

1. Double-click Tickoala. macOS says it cannot be verified — click **Done**.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** next to Tickoala and confirm.
4. Double-click Tickoala again — it starts, and stays allowed from now on.

On macOS 14 and earlier you can instead Control-click the app in Finder and
choose **Open**. Sequoia (15) and later removed that shortcut, hence the trip to
System Settings. If you would rather skip the warning entirely, build from
source below — a locally built app is never quarantined.

### Build from source

```bash
git clone https://github.com/joost-heijden/Tickoala.git
cd Tickoala
./scripts/build-app.sh
cp -R build/Tickoala.app /Applications/
open /Applications/Tickoala.app
```

Only the Xcode **Command Line Tools** are needed, not Xcode itself
(`xcode-select --install`); the build script falls back to macOS's own tools for
the icon. Update later with `./scripts/update.sh`.

Optionally put the CLI on your `PATH`:

```bash
ln -sf /Applications/Tickoala.app/Contents/Helpers/tickoala /usr/local/bin/tickoala
```

Tickoala can start itself at login: toggle it on the first-run welcome screen, or
add `Tickoala.app` under System Settings → General → Login Items.

### Releasing

Push a version tag and
[`.github/workflows/release.yml`](.github/workflows/release.yml) builds the app
on a macOS runner, ad-hoc signs it and attaches the zip to a GitHub release.
The same workflow can be run manually from the Actions tab; it then leaves the
zip as a downloadable artifact. For a warning-free download, the release step
would need an Apple Developer ID and notarization.

## Updating

**Downloaded the app?** Grab the newest `Tickoala-x.y.z.zip` from
[Releases](https://github.com/joost-heijden/Tickoala/releases), unzip it and
replace `Tickoala.app` in Applications with the new one. Your data stays put: it
lives in `~/Library/Application Support/Tickoala`, not in the bundle, so nothing
is lost. You will allow the new build once more, as described under
[Install](#install).

**Built from source?** Update with a single command:

```bash
./scripts/update.sh
```

It refuses to run when you have uncommitted changes, pulls the latest version
with `git pull --ff-only`, rebuilds the app, replaces the copy in `/Applications`
(override the destination with `TICKOALA_APP_DIR`), and restarts it. It builds
locally on purpose: a downloaded bundle is ad-hoc signed and would be rejected by
Gatekeeper.

The app also checks once a day whether a newer version exists, so the menu bar can
tell you when there is one. When a new version appears, the menu shows
**Version X available** with a button to the releases page where you can download
it. The first time a new version is seen it announces it once: as a notification
when macOS allows it, otherwise as a small dialog, because an ad-hoc signed build
cannot get notification permission on macOS 26. Either way it leads to the
releases page. That check is the only network access Tickoala makes: one request
per day to
`https://api.github.com/repos/joost-heijden/Tickoala/tags`. GitHub sees your IP
address and the version string in the `User-Agent` header (`Tickoala/<version>`);
nothing else is sent — no identifier, no usage data, no time entries, no location.
Everything about it lives under **Settings → Updates**: the version you are
running, **Check now**, and **Check for a new version once a day**. Turn it off
there, or with:

```bash
defaults write nl.tickoala.app update-check-disabled -bool true
```

### Location Services

macOS only reveals the name of the Wi-Fi network to apps that have **Location
Services** permission. Tickoala asks for this on first launch. Without it macOS
returns `<redacted>`, which is indistinguishable from "no Wi-Fi", so the app
deliberately sends no signals at all rather than guessing — the menu bar warns
you and **Settings → Detection** offers a button to fix it.

The same permission covers location detection. Only when you switch **Detect by**
to *Location* does the app read its own coordinates, and only to compare them with
the locations you stored for your clients. That comparison happens entirely on your
Mac: coordinates are never sent anywhere, and nothing is stored until you press
**Use current location** for a client.

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

# Optional: store a location, for detection by place instead of by network
tickoala location set --profile "Acme" --lat 52.37000 --lon 4.89000 --radius 200
```

All of this can also be done from the windows: **Manage customers**, **Manage
projects**, **Overview and corrections**, and under **Settings** the app-wide
options (General, Detection, Workday, Invoices, Updates) plus a **Manage** tab
that lists every one of those windows with a button to open it, so it is clear
where each thing is configured. The menu bar itself keeps
the daily work — the status per client, Start/Pause/Stop, **Overview**,
**Invoices** and **Settings** — and **Open Tickoala** opens the hub with the
same status per client plus the way into every window. While a window is open
Tickoala also takes a Dock icon and its own menu bar; close the last window and
it becomes a pure menu bar app again.

Not sure what a network is called? Connect to it — the menu bar shows the current
network and, if it isn't linked yet, offers to attach it to a client on the spot.

Detection is set under **Settings → Detection → Detect by**: *Wi-Fi network*
(the default) or *Location*. When Wi-Fi has no SSID — for example under Internet
Sharing — the primary wired connection is used instead, named after its DHCP
domain or, when the network has none, its router address. For location, open
**Manage customers** and press **Use current location** on a client; you can set
the radius and clear it again. Switching networks at the same place then no longer
looks like moving.

When you arrive at another client while a block is still running, Tickoala asks
first: keep the current project running, or start a new block there. It arrives as
a system notification with **Keep running** and **Start new block** buttons — or a
pop-up when notifications are turned off — and stays available in the menu bar so
you don't miss it. The same question appears when only the network changed but the
client did not.

For location detection the radius has a little slack: once you are at a client,
you stay there until you are clearly outside, so GPS jitter along the edge does
not flap your block. The same settings can be scripted:

```bash
tickoala location set   --profile "Acme" --lat 52.37000 --lon 4.89000 --radius 200
tickoala location list
tickoala location clear --profile "Acme"
```

## How it works

```
Network or location changes
        ↓
watcher turns it into a start/stop signal
        ↓
tracker validates it, applies the active project, writes to SQLite
        ↓
menu bar shows status and elapsed time
```

The signal source is deliberately dumb: it only reports "joined X" or "left X" —
where X is a network name, or a client's stored location when detection is set to
*Location*. Distance is measured from your coordinates to each client that has a
location, and the nearest one within its radius wins. All the judgement lives in
the tracker, which is what makes the behaviour predictable:

| Situation | Behaviour |
| --- | --- |
| Unknown network | nothing happens, just a log line |
| No project selected yet | no start; the menu bar asks you to pick one |
| Second start while already running | no second block |
| Repeated signal within the dedupe window | ignored (default 30s) |
| Leaving | the block keeps running until the workday end; it closes at the signal moment once the workday is over |
| Coming back the same day | the pending stop is cancelled, the same block continues |
| Roaming between two networks of one client | the same block continues, no new block |
| Wi-Fi has no SSID (Internet Sharing) | the wired connection is used instead, named after its DHCP domain or router |
| Detecting by location | the nearest stored client within its radius counts as the current context |
| Leaving to another customer | Tickoala asks: keep the current project running, or start a new block at the new place |
| Leaving with no timer running | log line only; never an empty or negative block |
| Two client networks active at once | nothing is stopped automatically; you choose |
| Mac asleep or shut down | no events invented; a block with no signal closes at the workday end, and only an implausible same-day block over 16h is marked `open` for correction |
| No Location Services permission | no signals at all; the menu bar asks for access |

A block ends at the moment of the stop signal, even though it is only closed once
the workday is over. That way a dropout during the day never splits your work, while
the night after you leave is not counted. The workday end (**Settings → General →
Workday**, or `workday-end-minutes` from the CLI) is the fallback last moment: a
block that never got a stop signal — the Mac slept, Tickoala was closed — is closed
there instead of running into the night and asking about it the next morning.

The same place sets a workday **start** (`workday-start-minutes`). Automatic
check-ins and departures are rounded to the nearest whole or half hour, so a
check-in at 08:07 with an 08:00 start counts from 08:00. Within half an hour of the
start the start time wins; further out the nearest half hour is used (08:40 → 08:30,
08:50 → 09:00). Manually started or stopped blocks keep the exact minute.

Because the source is just an event feed, it's replaceable. A CLI adapter is
included if you'd rather drive it from something else:

```bash
tickoala start --context "Acme-Guest"
tickoala stop  --context "Acme-Guest"
```

## Undo and corrections

Everything you do to customers, projects and blocks can be taken back with
**⌘Z**, and put back with **⇧⌘Z**: adding or deleting a block, editing one,
recording a break, switching the active project, deleting a customer, and adding,
editing, activating or deleting a project. Deleting a project leaves its blocks
in place but drops the project link; undoing the delete puts the project back and
relinks those blocks. Deleting a customer takes their projects, blocks and
invoices along; undo restores the whole customer exactly as it was.

While the cursor is in a text field, ⌘Z takes back typing as usual. The menu bar
shows what the next undo would be — **Undo Delete project**, for example.

The Overview window is where you correct and add blocks by hand, with day, week
and month totals. Each row has a context menu with **Edit**, **Duplicate** and
**Delete**, and the toolbar carries the same three: **⌘D** duplicates the selected
block, **Delete** or **⌘Delete** removes it. Deleting asks for confirmation first
and can be undone with ⌘Z. Manually edited, added and break times are floored to
whole minutes, so a correction from 08:00 to 16:30 is stored as exactly 8:30 —
automatic tracking keeps its real seconds.

## Break deduction

There are two ways a break gets taken off your hours.

**Automatic, per client.** Set how much break to subtract, and from how many
hours it applies. Both are configured separately, and it's off by default.

- applies **per client per day**, not per block — pausing during the day doesn't
  cause it to be subtracted twice
- the threshold is **inclusive**: set to 6:00, a day of exactly 6 hours already has
  the break subtracted
- below the threshold nothing is subtracted
- never subtracts more than you actually worked, so a day can't go negative

**By hand, on a block.** Open a block from the Overview and turn on **Break
recorded**, with its own start and end. The block keeps its start and end, so the
day stays a single row; the row shows the break in the **Break** column and the
worked duration without it. A day with a recorded break is left to that break: the
automatic rule does not subtract a second time.

The automatic rule is a **calculation on top of your raw blocks**. Time entries are
never modified by it, so you can change or disable the rule at any time — including
retroactively. A break recorded by hand does live on the block. Totals, the menu bar
and the export show net hours; the per-project breakdown keeps the automatic
deduction out, because that break belongs to a day rather than to a project.

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
export carries `hourly_rate` and `currency` next to every block and a `break`
column next to `end` with the negative break deduction for that client on that
day (on the last block row of the day). Clients without a rate simply produce no
rate.

If you like to watch it grow, turn on the running month revenue under
**Settings → General**: the same amount for the current month then sits next to
the menu bar icon and per customer in the menu, counting up every second while a
block runs. Both are off by default.

## Billing rules

Consultancy invoices rarely charge the exact clock time: they round to quarters,
round up, bill a minimum, and pay extra for evenings and weekends. Per client you
can set all of it from **Manage customers → Billing rules**, or from the command
line. Every rule is off by default, so a client without them invoices exactly as
before.

- **Round** the invoiced time to a number of minutes (15 for quarters), to the
  nearest or up.
- **Minimum**: bill at least this much per invoice; a light period is topped up
  with a **Minimum billing** line.
- **Evening surcharge**: a percentage on work after the evening start (18:00 by
  default), added as its own line.
- **Weekend surcharge**: a percentage on Saturday and Sunday work.

The rules are a calculation on top of the recorded blocks, never an edit of them,
so you can set, change or clear them at any moment.

```bash
tickoala billing set --profile "Acme" --round 15 --round-up true --minimum 1:00
tickoala billing set --profile "Acme" --evening 25 --weekend 50 --evening-start 18:00
tickoala billing clear --profile "Acme"
```

## Travel time

A block is **work**, **travel to a client** or the **commute**. Travel and commute
are recorded the same way but land on the invoice as their own line:

- **Travel** is billed at the client's travel rate; without one it falls back to
  the hourly rate.
- **Commute** (Dutch *woon-werkverkeer*) is only billed when its own rate is set;
  otherwise it is recorded but stays off the invoice.

Set the rates per client under **Manage customers**, or from the command line:

```bash
tickoala profile edit --profile "Acme" --travel-rate 65.00 --commute-rate 0
tickoala timer start --profile "Acme" --kind travel
tickoala entry add --profile "Acme" --number 2401 --start "2026-09-10 08:00" --end "2026-09-10 09:00" --kind travel
tickoala entry edit --id 12 --kind commute
```

In the overview each block has a **Kind** picker, and the timeline draws travel and
commute alongside work. Travel time never counts towards a project budget.

## Project budgets

For fixed-price work you can give a project an hour budget and watch it burn
down. It is entirely optional and off by default: a project without a budget
shows nothing extra, and nothing is enforced.

Set the budget under **Manage projects**: each row has a **Budget** field in
hours (leave it empty for none). A project with a budget then shows how much is
left next to it, green, turning orange at 80% and red when the budget is passed.
The same line appears in the menu under the customer.

Set the budget from the command line too:

```bash
tickoala project edit --profile "Acme" --number 2401 --budget 80   # 80 hours
tickoala project edit --profile "Acme" --number 2401 --budget 1:30 # 1.5 hours
tickoala project edit --profile "Acme" --number 2401 --budget 0    # clear it
```

The budget counts every block booked on the project over all time, with any
recorded break already taken off — the same figure as a project row in a report.
Like the break deduction it is a calculation on top of your raw blocks, so you
can set, change or clear a budget at any moment without touching the recorded
time.

To be warned when a budget reaches 80% and 100%, turn on **Settings → General →
Project budgets → Warn when a project reaches 80% and 100% of its hour budget**.
It is off by default. Each threshold warns once, as a notification (or a dialog
when notifications are unavailable), and the level is remembered so a restart
does not warn again. Changing the budget re-arms the warning.

## Expenses and mileage

On top of the hours you can bill expenses and mileage for a client. This is
entirely optional: a client without expenses invoices exactly as before.

Open **Expenses** from the menu (or the hub) and pick a customer. Every entry has
a date, a description and either an amount (parking, materials) or a number of
kilometres at a rate. Billable entries are added to that customer's invoice as
their own lines, next to the project hours; the VAT is charged over hours and
expenses together. Uncheck **Add to the invoice** to keep a cost out of the
invoice while still recording it.

Mileage uses the client's **mileage rate** (in the header of the Expenses
window, or under the customer). The amount is fixed the moment you record the
claim, so changing the rate later never alters an old entry. The same via the
command line:

```bash
tickoala profile edit --profile "Acme" --km-rate 0.23        # default rate per km
tickoala expense add --profile "Acme" --description "Parking" --amount 12.50
tickoala expense add --profile "Acme" --description "Travel" --km 120 --rate 0.23
tickoala expense list --profile "Acme" --period month
tickoala expense delete --id 4
```

The amount of a mileage claim is `kilometres × rate`; a plain expense stores the
amount. Both count towards the invoice's subtotal and VAT. The invoices window
shows the expenses that will be added on top of the hours, and the invoice PDF
gives each its own row, with the quantity (for example `120 km`) and the rate.

## Retainers

A retainer is a fixed monthly amount per client — a support contract, a
subscription — added to that client's invoice automatically as its own line. Set
it under **Manage customers → Retainer**, or:

```bash
tickoala retainer set --profile "Acme" --amount 1500 --description "Support contract"
tickoala retainer list
tickoala retainer clear --profile "Acme"
```

The amount is invoiced on top of the hours, and VAT is charged over it like any
other line. An amount of zero, or an inactive retainer, is never billed.

A retainer can **recur** monthly, quarterly or yearly, and can carry an **end
date**; once it has ended it stops being added from the month after its last day,
and a new end that would close before the current one is refused, so a running
agreement is never shortened by accident.

```bash
tickoala retainer set --profile "Acme" --amount 1500 --recurrence quarterly --ends 2026-12-31
```

For a support contract that does not depend on tracked hours, the retainer can be
billed **on its own**, as a fixed-fee invoice with a single line and no hours:

```bash
tickoala retainer render-invoices --month 2026-01              # report what would be billed
tickoala retainer render-invoices --month 2026-01 --out ~/Desktop/invoices
```

Without `--profile` it does every client whose retainer covers that month; running
it twice reuses the same number, so it is safe in a monthly cron.

## Holidays and vacation

Under **Settings → Workday** you can mark public holidays and vacation days. A
marked day is not a normal working day: the workday-end fallback no longer cuts it
off, and a block without a stop signal closes at the end of that day instead. The
days are global — a day off is a day off for every client.

```bash
tickoala holiday add 2026-12-25 --label "Christmas"
tickoala holiday add 2027-01-02 --kind vacation
tickoala holiday list
tickoala holiday remove 2026-12-25
```

## UBL/Peppol

Every invoice can be exported as a **UBL 2.1** file (the Peppol BIS billing
format), for import into your bookkeeping package or an e-invoicing portal. In the
invoices window press **Export UBL…** on a customer, or use the history row's
**UBL…** button; from the command line:

```bash
tickoala invoice --profile "Acme" --month 2026-08 --ubl ~/Desktop/invoice.xml
tickoala invoice --profile "Acme" --month 2026-08 --out ~/Desktop/invoice.pdf --ubl ~/Desktop/invoice.xml
```

It is the same invoice the PDF shows, as XML: both parties, the lines with their
quantities and rates, the VAT (with reverse charge as category `AE`), and the
totals. Nothing is sent anywhere — the file is written to the path you choose.

## VAT return

Tickoala keeps a quarterly VAT overview per rate, ready to copy into the
Belastingdienst's form. It is a report, nothing more: no filing, no server.

Open **VAT return** from the menu, step to the quarter with the arrows, and read
the turnover and VAT per rate. The figures come from the same calculation an
invoice uses: net hours × the client's rate, plus the billable expenses, with the
client's VAT rate over the sum. A client with 0% (reverse charge) lands in a 0%
line; a quarter without work shows nothing.

A **credit note** is counted as negative turnover and negative VAT in the quarter
it was issued, the way the Belastingdienst wants a correction booked. That also
means a credit issued in a later quarter reduces that quarter, without reopening
the quarter of the original invoice.

```bash
tickoala vat --year 2026 --quarter 3
```

> The return assumes euro clients. Amounts are shown as-is; a client invoicing in
> dollars is not converted.

## Invoices

On the **first weekday of every month** (if the 1st falls on a Saturday or
Sunday, the Monday after) Tickoala opens the invoices window for the month that
just ended. It lists every customer with hours, with a PO field and their email
address, and for each one you can:

- **Create PDF…** — a one-page A4 invoice: your details, the customer, the
  project lines with hours and rate, the automatic break deduction, subtotal,
  VAT and the total.
- **Export CSV…** — the same month's hours as a CSV, for your own bookkeeping.
- **Approve & send** — emails the invoice PDF to the customer, after a
  confirmation. Tick **Include hours CSV** to attach that month's hours as well;
  you can set that as the default under **Settings → Invoices**.

The window is always available from the menu (**Invoices**, ⌘I), at any moment
of the month. Opened that way it starts on the current month, so the hours
booked so far can be invoiced straight away; the reminder keeps starting on the
month that just ended. The arrows next to the month move it either way, so any
month can be invoiced by hand.

Put your own details under **Settings → Invoices** (or from the invoices
window): name, address, KvK, VAT number, IBAN, email, payment term,
invoice number prefix, and an optional logo. The default VAT rate for new
customers is set there too (21% by default). Per customer you set the billing
address, their VAT number, the VAT rate (change it per customer for 9%, 0% or
reverse charge), a default PO number and the invoice email address.

Invoice numbers are handed out once per customer per month and never repeat:
reopening the same month keeps its number, and the counter skips any number that
already exists after a manual edit. The counter only ever moves forward, so a
number stays spent even after its invoice was removed — deleting a document can
never hand the same number out twice. A four-digit year in the prefix follows the
calendar, so `2026-` becomes `2027-` on its own; a prefix without a year is left
alone.

Below the customer list, **Invoice history** shows every invoice ever issued
with its month, customer, number, total and issue date. Click a row to jump the
window to that month, or use its **PDF**, **CSV** or **Resend** buttons to
rebuild the document, export the hours or send the invoice again.

When an invoice went out wrong, **Credit** makes the credit note that reverses it:
the same customer and period with negative lines, its own number, and a reference
to the original. The original stays in the history and keeps its number. A credit
is stored like an invoice, gets its own **PDF** and UBL (a `CreditNote` with type
381 and a `BillingReference` to the original) and can be sent to the customer.
On the command line: `tickoala credit --number 2026-0007 --out ~/Desktop/credit.pdf`.

### Sending by email

Fill in your SMTP server under **Settings → Invoices → Email (SMTP)**: server,
port, username, from-address and password. The password goes into the macOS
**Keychain**, never into the database. Use **Test** to send yourself a message.

Tickoala uses **implicit TLS (SMTPS, normally port 465)**. STARTTLS on port 587
is not supported, because macOS's networking framework cannot upgrade a
connection halfway; providers that offer port 465 (Gmail with an app password,
Fastmail and most others) work.

## Shortcuts and the hotkey

Tickoala exposes a few actions to **Shortcuts** (and Siri): *Start timer*, *Stop
timer* and *Today's hours*. They open the same database with the same rules, so a
shortcut behaves exactly like the menu. Look for Tickoala under the Shortcuts app's
apps, or ask Siri, for example: *"Start Tickoala for Acme"*.

There is also a system-wide hotkey, **⌃⌥T**, that starts or stops without touching
the menu bar: it stops whatever is running, or starts the chosen customer when
nothing does. It uses Carbon's hotkey API, so it needs no Accessibility
permission.

> A widget is not included: it needs a WidgetKit extension that the dependency-free
> SwiftPM build does not produce. Shortcuts and the hotkey cover the same need.

## Command line

```bash
tickoala status                 # also --json
tickoala report week            # or day / month, with --date and --profile
tickoala profile list           # clients, with their hourly rate
tickoala rate set --profile "Acme" --rate 87.50
tickoala project edit --profile "Acme" --number 2401 --budget 80   # optional hour budget
tickoala expense add --profile "Acme" --description "Parking" --amount 12.50
tickoala expense add --profile "Acme" --description "Travel" --km 120 --rate 0.23
tickoala billing set --profile "Acme" --round 15 --round-up true --minimum 1:00
tickoala retainer set --profile "Acme" --amount 1500 --description "Support contract"
tickoala holiday add 2026-12-25 --label "Christmas"
tickoala timer start --profile "Acme" --kind travel   # work (default), travel or commute
tickoala vat --year 2026 --quarter 3   # quarterly VAT return
tickoala entry list --period week
tickoala entry add --number 2401 --start "2026-09-10 09:00" --end "2026-09-10 17:00"
tickoala entry edit --id 12 --end "2026-09-10 16:30" --tag "meeting, admin"
tickoala export --period month --out ~/Desktop/hours-september.csv
tickoala invoice --profile "Acme" --month 2026-08 --po "PO-2026-114" --out ~/Desktop/invoice.pdf
tickoala credit --number 2026-0114 --out ~/Desktop/credit.pdf   # reverse an invoice
tickoala invoices --overdue     # what is unpaid and past its due date
tickoala paid --number 2026-0114
tickoala import --from toggl --file ~/Downloads/toggl_export.csv --dry-run
tickoala import --from toggl --file team_export.csv --user "Jane"   # only your rows
tickoala backup --out ~/Desktop/tickoala-2026-10-02.sqlite3
tickoala restore --peek ~/Desktop/tickoala-2026-10-02.sqlite3        # what is in it?
tickoala restore --from ~/Desktop/tickoala-2026-10-02.sqlite3        # asks to confirm
tickoala events                 # what was received and what happened with it
tickoala config list            # dedupe window and thresholds
tickoala db                     # path to the database
```

`tickoala help` lists everything.

## Your data

Everything lives in
`~/Library/Application Support/Tickoala/tickoala.sqlite3` (override with the
`TICKOALA_DB` environment variable). It holds time entries, client names, network
names, the locations you saved for clients, projects, notes, billing details,
issued invoices and a log of received events. A chosen invoice logo is copied into
that same folder. Nothing is ever uploaded — the only network requests are the
daily version check described under [Updating](#updating) and the invoice email you
send yourself. The SMTP password is kept in the macOS Keychain, never in this file.

Backing up is copying that one file.

## Development

```bash
swift build && .build/debug/TickoalaChecks
```

The suite covers start, stop, pause, resume, duplicate events, brief dropouts, two
clients at once, multiple networks per client, project linking, switching and
renumbering, unique project numbers, break deduction, project budgets and their
80%/100% thresholds, expenses and mileage on the invoice, the quarterly VAT
return, restarting with an open timer, day/week/month totals, CSV export,
invoicing, billing rules, travel time, retainers, holidays, the UBL/Peppol
export, the running month revenue, and runs the real CLI as a separate process.

It runs as a plain executable rather than through `swift test`: XCTest and
swift-testing ship with full Xcode, not with the Command Line Tools, and this
project deliberately builds with just the CLT.

| Target | Purpose |
| --- | --- |
| `TickoalaCore` | data model, timer rules, totals, CSV export, invoices, PDF and email |
| `TickoalaApp` | menu bar app: Wi-Fi detection, overview, projects, corrections, invoices |
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
- Sending invoices by email only supports implicit TLS on port 465, not STARTTLS
  on port 587 (a limitation of macOS's `Network.framework`).

## The name

A koala barely moves and stays put for hours — which is exactly the behaviour
this thing measures. Add the tick of a clock and you get Tickoala.

## Contributing

Issues and pull requests are welcome. Please run `.build/debug/TickoalaChecks`
before submitting; the suite is fast and has no external dependencies.

## License

MIT — see [LICENSE](LICENSE).
