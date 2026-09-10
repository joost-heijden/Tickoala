# WifiHours

Lokale urenregistratie voor macOS. ControlPlane detecteert de werkcontext (het
wifi-netwerk), WifiHours vertaalt dat naar start- en stopgebeurtenissen en houdt
de uren bij in een SQLite-bestand op de eigen Mac. Geen account, geen server,
geen netwerkverbinding nodig.

## Opbouw

| Deel | Wat het doet |
| --- | --- |
| `WifiHoursCore` | datamodel, timerregels, totalen, CSV-export |
| `wifihours` | het adaptercommando en de volledige bediening vanaf de opdrachtregel |
| `WifiHoursApp` | de menubalk-app met overzicht en correcties |
| `WifiHoursChecks` | de testsuite |

De adapter is bewust dom: hij geeft alleen `start` of `stop` met een contextnaam
door. De tracker beslist of dat signaal geldig is, voorkomt dubbele blokken en
bewaart de bron en context van elk event.

## Bouwen

```bash
./scripts/build-app.sh          # bouwt build/WifiHours.app plus het adaptercommando
open build/WifiHours.app        # start de menubalk-app
```

Zet het adaptercommando eventueel binnen handbereik:

```bash
ln -sf "$PWD/build/WifiHours.app/Contents/Helpers/wifihours" /usr/local/bin/wifihours
```

Wil je de app bij het inloggen starten: Systeeminstellingen → Algemeen →
Inloggen → Openen bij inloggen → `build/WifiHours.app` toevoegen (of de app eerst
naar `/Applications` verplaatsen).

## Inrichten

Een profiel (organisatie/klant) mag aan meerdere wifinetwerken hangen —
bijvoorbeeld een gast- en een personeelsnetwerk bij dezelfde klant, of meerdere
vestigingen. `--context` accepteert een kommagescheiden lijst; extra netwerken
kunnen ook later nog toegevoegd worden.

```bash
wifihours profile add --name "Efteling" --context "Efteling-Guest,Efteling-Staff"
wifihours profile add --name "Organisatie B" --context "Kantoor B"

# een netwerk later nog toevoegen of ontkoppelen
wifihours profile context add    --profile "Efteling" --context "Efteling-Magazijn"
wifihours profile context remove --profile "Efteling" --context "Efteling-Guest"
wifihours profile context list   --profile "Efteling"

wifihours project add --profile "Efteling" --number 2401 --name "Migratie datawarehouse"
wifihours project add --profile "Efteling" --number 2402 --name "Onderhoud"
wifihours project select --profile "Efteling" --number 2401
```

`--context` is exact de SSID (netwerknaam) zoals ControlPlane die doorgeeft.
Eén netwerk hoort maar bij één profiel; projectnummers zijn uniek binnen één
profiel, hetzelfde nummer mag bij een ander profiel wel.

## ControlPlane koppelen

ControlPlane matcht op één SSID per context-regel. Heeft een klant meerdere
netwerken, maak dan per SSID een aparte ControlPlane-context aan en laat de
acties van elke context precies díe SSID-naam doorgeven aan de adapter — de
tracker herkent zelf dat het om hetzelfde profiel gaat, via de koppeling die
hierboven is ingericht.

1. Maak in ControlPlane per SSID een context aan, bijvoorbeeld `Efteling-Guest`
   en `Efteling-Staff`.
2. Koppel er telkens een regel aan: **Wi-Fi network** met die ene SSID.
3. Voeg per context twee acties toe (Actions → Run Shell Script), met als
   parameter de SSID van díe context:

   | Context | Wanneer | Script | Parameter |
   | --- | --- | --- | --- |
   | `Efteling-Guest` | Bij activeren | `/pad/naar/WifiHours/scripts/controlplane-event.sh` | `start "Efteling-Guest"` |
   | `Efteling-Guest` | Bij verlaten | `/pad/naar/WifiHours/scripts/controlplane-event.sh` | `stop "Efteling-Guest"` |
   | `Efteling-Staff` | Bij activeren | `/pad/naar/WifiHours/scripts/controlplane-event.sh` | `start "Efteling-Staff"` |
   | `Efteling-Staff` | Bij verlaten | `/pad/naar/WifiHours/scripts/controlplane-event.sh` | `stop "Efteling-Staff"` |

   Kan een actie geen argumenten meegeven, maak dan twee kleine wrappers per SSID:

   ```bash
   #!/bin/bash
   exec /pad/naar/WifiHours/scripts/controlplane-event.sh start "Efteling-Guest"
   ```

   Roamt de Mac tussen `Efteling-Guest` en `Efteling-Staff` (bijvoorbeeld tussen
   twee ruimtes), dan ziet de tracker dat als een korte onderbreking binnen
   dezelfde klant: het lopende blok loopt gewoon door in plaats van te splitsen.

Het adapterscript faalt nooit richting ControlPlane; alles komt in
`~/Library/Logs/WifiHours-adapter.log`. De verwerkte events staan ook in de
database: `wifihours events`.

## Wat de tracker met een signaal doet

| Situatie | Gedrag |
| --- | --- |
| Onbekende wifi-context | niets automatisch, alleen een logregel |
| Nog geen project gekozen | geen start, wel een melding in de menubalk |
| Tweede start terwijl de timer loopt | geen nieuw blok |
| Herhaald event binnen het tijdvenster | genegeerd (standaard 30 seconden) |
| Vertrek | stop wordt gepland; pas na de wachttijd definitief (standaard 90 seconden) |
| Korte wifi-uitval binnen die wachttijd | de geplande stop vervalt, het blok loopt door |
| Vertrek zonder lopende timer | alleen een logregel, geen leeg of negatief blok |
| Twee werkcontexten tegelijk | er wordt niets gestopt; de app vraagt om een keuze |
| Slaapstand of afsluiten | er worden geen gebeurtenissen verzonnen; een blok dat langer dan 16 uur loopt krijgt de status `open` en vraagt om correctie |

Het einde van een blok is altijd het moment van het stopsignaal, niet het moment
waarop de wachttijd afliep.

## Menubalk

De menubalk toont `Werkend`, `Pauze`, `Gestopt` of `Aandacht nodig`, met bij een
lopende timer de verstreken tijd. Per organisatie staan in het menu het actieve
project (`nummer — naam`) met een snelle projectwissel, de dag- en weektotalen en
knoppen voor pauzeren, hervatten en stoppen.

Pauzeren sluit het lopende blok af, hervatten begint een nieuw blok. Een
handmatige pauze wint van een automatisch startsignaal: kom je terug op kantoor
terwijl je op pauze staat, dan blijft de pauze staan tot je zelf hervat.

Een projectwissel tijdens het werk sluit het lopende blok af en begint een nieuw
blok op het nieuwe project, zodat tijd bij het juiste project blijft staan.

**Overzicht en correcties…** opent een venster met het dag-, week- of
maandoverzicht: totalen per project, alle blokken, het corrigeren van begin,
einde, project en notitie, blokken toevoegen of verwijderen, en CSV-export van de
getoonde periode.

## Opdrachtregel

```bash
wifihours status                 # ook --json
wifihours report week            # of day / month, met --date en --profile
wifihours entry list --period week
wifihours entry add --number 2401 --start "2026-09-10 09:00" --end "2026-09-10 17:00" --note "vergeten te starten"
wifihours entry edit --id 12 --end "2026-09-10 16:30"
wifihours export --period month --out ~/Bureaublad/uren-september.csv
wifihours events                 # wat ControlPlane heeft doorgegeven en wat ermee gebeurde
wifihours config list            # wachttijden en drempels
wifihours config set stop-grace-seconds 120
wifihours db                     # pad naar de database
```

`wifihours help` geeft de volledige lijst.

## Gegevens en privacy

Alles staat in `~/Library/Application Support/WifiHours/wifihours.sqlite3` (te
overschrijven met de omgevingsvariabele `WIFIHOURS_DB`). Opgeslagen worden:
tijdregistraties, profielnamen, ControlPlane-contextnamen, projecten, notities en
een log van de ontvangen events. Geen locatiegegevens, geen netwerkverkeer.

Back-up maken is een kwestie van dat ene bestand kopiëren (samen met de
`-wal`- en `-shm`-bestanden, of na `wifihours status` als de app niet draait).

## Tests

```bash
swift build && .build/debug/WifiHoursChecks
```

De suite dekt start, stop, pauze, hervatten, dubbele events, korte wifi-uitval,
twee contexten tegelijk, projectkoppeling en -wissel, unieke projectnummers,
herstarten met een open timer, dag-/week-/maandtotalen en CSV-export, en draait
het echte adaptercommando als los proces.

De suite draait als gewoon programma en niet via `swift test`: XCTest en
swift-testing zitten alleen in de volledige Xcode, niet in de Command Line Tools.
Is Xcode geïnstalleerd, dan kunnen de checks één op één naar swift-testing.

## Handmatig te testen op de Mac

Dit deel vraagt om echte wifi en ControlPlane:

- binnenkomen op kantoor A en B (start, juiste profiel, juiste project);
- vertrekken (stop na de wachttijd, juiste eindtijd);
- korte wifi-uitval (blok loopt door, geen tweede blok);
- slaapstand over de nacht (blok wordt `open`, geen verzonnen einde);
- beide kantoren kort na elkaar (waarschuwing, geen automatische stop).
