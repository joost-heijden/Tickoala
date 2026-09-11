# Opdracht: updates zichtbaar en makkelijk maken

Werk dit uit in de repo `joost-heijden/Tickoala` (macOS-menubalkapp, Swift Package
Manager, geen third-party dependencies). Deze opdracht is zelfstandig te lezen:
alles wat je nodig hebt staat hieronder.

## Waarom

Wie de app installeert volgt de README: `git clone` → `./scripts/build-app.sh` →
`cp -R build/Tickoala.app /Applications/`. Dat is een momentopname. Er is niets
dat later kijkt of er een nieuwere versie is, en de app weet zelf niet eens
welke versie hij is: `CFBundleShortVersionString` staat hardgecodeerd op `1.0`
in `scripts/build-app.sh`. Er zijn geen tags en geen releases.

Doel: iemand die de app draait merkt dát er een nieuwe versie is, en kan met één
commando bij zijn.

Bewust **niet** in scope: Sparkle, een Homebrew-cask, notarisatie, en de app die
zichzelf downloadt en vervangt. De app wordt ad-hoc ondertekend
(`codesign --sign -`); een zip die van GitHub gedownload wordt krijgt een
quarantainevlag en wordt door Gatekeeper geweigerd zolang er geen Developer ID
plus notarisatie is. Iedereen bouwt dus zelf, en daar is dit plan op gebouwd.

## Deel 1 — `scripts/update.sh`

Eén commando dat bijwerkt en herstart. Volg de stijl van `scripts/build-app.sh`
(`set -euo pipefail`, `root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`,
meldingen in het Nederlands).

Stappen, in deze volgorde:

1. Weiger als dit geen git-clone is (iemand heeft een zip gedownload) met een
   uitleg die zegt wát er dan moet gebeuren.
2. Weiger als de werkmap vuil is (`git status --porcelain` niet leeg). Nooit
   stilletijd over andermans werk heen bouwen.
3. `git pull --ff-only`. Geen rebase, geen merge: als het niet vooruit kan, moet
   de gebruiker dat zelf zien.
4. Sla de versie van vóór en na de pull op (`git describe --tags --always`) en
   meld aan het eind welke stap gezet is. Is er niets veranderd, zeg dat dan en
   stop — niet nodeloos herbouwen.
5. `"$root/scripts/build-app.sh" release`.
6. Stop een draaiende app: `osascript -e 'tell application "Tickoala" to quit'`,
   daarna maximaal een paar seconden wachten tot het proces weg is, met
   `pkill -x Tickoala` als laatste redmiddel.
7. `rm -rf "$doel/Tickoala.app"` en `cp -R build/Tickoala.app "$doel"/`. Let op:
   `cp -R` moet de symlink in de top van de bundel als symlink overnemen (dat
   doet het op macOS); zie deel 2 van `build-app.sh` voor waarom die er staat.
8. `open "$doel/Tickoala.app"`.

Doelmap instelbaar via `TICKOALA_APP_DIR`, met `/Applications` als standaard.

## Deel 2 — echte versienummers

Nu weet de app niet wat hij is, dus kan hij ook niets vergelijken.

- Versietags met de vorm `v1.1.0`. Zet meteen `v1.1.0` op de huidige `main`, dat
  is de eerste versie mét de nieuwe iconen.
- `scripts/build-app.sh` leidt de versie af uit git:
  `CFBundleShortVersionString` uit `git describe --tags --abbrev=0` zonder de
  `v`, en `CFBundleVersion` uit `git rev-list --count HEAD`.
- Zonder tags (verse clone, losse zip) mag de build **niet** breken: val terug
  op `0.0.0` en laat de controle uit deel 3 zich dan stilhouden.
- De Info.plist wordt geschreven met een heredoc met aanhalingstekens
  (`<<'PLIST'`), zodat er nu niets wordt uitgevouwen. Houd dat zo en vervang na
  afloop twee plaatsaanduidingen (bijvoorbeeld `__VERSIE__` en `__BUILD__`) met
  `sed`. Een heredoc zónder aanhalingstekens werkt vandaag ook, maar breekt
  zodra iemand ooit een `$` in die plist zet.

## Deel 3 — melding in de app

### Vergelijken (in `TickoalaCore`, want dat is te controleren)

Nieuw bestand `Sources/TickoalaCore/VersionCheck.swift`:

- Een `Version`-waarde die `"1.2.3"` en `"v1.2.3"` inleest en die te vergelijken
  is. Ontbrekende delen tellen als nul, zodat `1.2` en `1.2.0` gelijk zijn.
- Onleesbare invoer levert `nil`, geen crash en geen gok.
- Een functie die uit een lijst beschikbare versies teruggeeft óf er een nieuwere
  is dan de huidige — en `nil` bij een gelijke of oudere versie, en altijd `nil`
  als de huidige versie `0.0.0` is (ontwikkelbuild of geen tags).

Geen netwerk in dit bestand. Dat is precies waarom het hier staat.

### Ophalen (in `TickoalaApp`)

Nieuw bestand `Sources/TickoalaApp/UpdateChecker.swift`, een `ObservableObject`
met `@Published private(set) var beschikbareVersie: String?`.

- `https://api.github.com/repos/joost-heijden/Tickoala/releases/latest`, veld
  `tag_name`. Een 404 betekent "nog geen release" en is geen fout.
- GitHub eist een `User-Agent`-header; zonder krijg je een 403. Gebruik
  `Tickoala/<versie>`.
- Hoogstens één controle per 24 uur. Het moment van de laatste controle in
  `UserDefaults`. Bij de start van de app kijken, daarna hoeft er niets extra's:
  `AppModel` heeft al een timer die elke seconde tikt.
- Time-out van tien seconden, geen herhaalpogingen. Mislukt het, dan gebeurt er
  zichtbaar niets — een menubalkapp hoort niet te zeuren over een haperend
  netwerk.
- Uit te zetten met een sleutel in `UserDefaults`. Geen instelling in de
  `settings`-tabel: die is `Int`-gebaseerd, wordt gedeeld met het
  adaptercommando, en dit gaat alleen over de app.

### Tonen (in `MenuContent.swift`)

Boven het laatste blok met "Stop Tickoala":

- `Text("Versie X beschikbaar")` als er iets is.
- Een knop die de release-pagina opent met `NSWorkspace.shared.open`.
- Een knop om de controle uit te zetten.
- Toon niets zolang er geen nieuwere versie is. Geen "je bent bij"-regel, geen
  voortgang, geen foutmelding.

## Deel 4 — controles

De suite is een eigen programma, geen XCTest: `Sources/TickoalaChecks`, met
`Harness.suite` en `Harness.test`. Voeg `VersionChecks.swift` toe met een
`versionChecks()` en roep die aan in `Sources/TickoalaChecks/main.swift`.

Dek in elk geval: `1.2.0` is nieuwer dan `1.1.9`; gelijke versies geven niets;
de `v` ervoor maakt niet uit; `1.2` en `1.2.0` zijn gelijk; rommel levert `nil`;
en `0.0.0` als huidige versie meldt nooit een update. Geen netwerk in de checks.

## Deel 5 — README

De README is Engels (de rest van de repo is Nederlands, houd dat zo). Voeg na
"Install" een "Updating" toe met `./scripts/update.sh`, en schrijf eerlijk op
wat de controle doet: één verzoek per dag naar `api.github.com`, waarbij GitHub
het IP-adres en de versie in de `User-Agent` ziet, er niets anders wordt
verstuurd, en hoe je het uitzet. De README belooft nu nadrukkelijk dat er niets
van de Mac af gaat; die belofte moet kloppen blijven.

## Conventies in deze repo

- Commentaar in het Nederlands, en het legt uit *waarom* iets er staat, niet wat
  de regel doet. Kijk hoe `WifiWatcher.swift` en `build-app.sh` dat doen.
- Commitberichten in het Nederlands, in hele zinnen, met de reden erbij.
- Geen dependencies. Alleen Foundation, AppKit en SwiftUI.
- Swift-taalmodus v5, minimaal macOS 13.
- `swift build -c release` en `swift run TickoalaChecks` moeten schoon blijven.

## Klaar als

1. `./scripts/update.sh` werkt vanaf elke map, weigert netjes bij een vuile
   werkmap, en levert een draaiende app op de nieuwe versie.
2. `/Applications/Tickoala.app/Contents/Info.plist` bevat het echte versienummer.
3. Met een versietag die hóger is dan de geïnstalleerde versie verschijnt de
   melding in het menu; met een gelijke tag verschijnt er niets.
4. `swift run TickoalaChecks` is groen, inclusief de nieuwe controles.
5. Zonder netwerk start en werkt de app zonder vertraging of melding.

## Let op bij het begin

In de werkmap staan nu wijzigingen van een andere thread in
`Sources/TickoalaApp/AppModel.swift`, `Sources/TickoalaApp/OverviewWindow.swift`,
`Sources/TickoalaCore/Store.swift` en
`Sources/TickoalaChecks/PersistenceChecks.swift`. Commit die niet mee, en stem
af voordat je `MenuContent.swift` of `AppModel.swift` aanraakt.
