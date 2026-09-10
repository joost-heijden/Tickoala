# WifiHours

Lokale urenregistratie voor macOS. De app ziet zelf op welk wifinetwerk de Mac
zit, vertaalt elke wisseling naar een start- of stopgebeurtenis en houdt de uren
bij in een SQLite-bestand op de eigen Mac. Geen account, geen server, geen
netwerkverbinding nodig.

## Opbouw

| Deel | Wat het doet |
| --- | --- |
| `WifiHoursCore` | datamodel, timerregels, totalen, CSV-export |
| `wifihours` | het adaptercommando en de volledige bediening vanaf de opdrachtregel |
| `WifiHoursApp` | de menubalk-app: wifi-detectie, overzicht, projecten en correcties |
| `WifiHoursChecks` | de testsuite |

De signaalbron is bewust dom: die geeft alleen `start` of `stop` met een
netwerknaam door. De tracker beslist of dat signaal geldig is, voorkomt dubbele
blokken en bewaart de bron en context van elk event. Daardoor is de bron
uitwisselbaar: de app doet het zelf, en het adaptercommando kan hetzelfde
signaal geven vanuit een extern programma.

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

## Wifi-detectie en toestemming

De app kijkt elke paar seconden welk wifinetwerk actief is. Wisselt dat, dan
gaat er een stopsignaal naar het oude netwerk en een startsignaal naar het
nieuwe.

Sinds macOS Sonoma geeft het systeem de netwerknaam alleen vrij aan programma's
met toestemming voor **Locatievoorzieningen**. Zonder die toestemming levert
macOS `<redacted>` op, wat niet te onderscheiden is van "geen wifi". Bij de
eerste start vraagt WifiHours die toestemming daarom; zolang die er niet is,
worden er bewust géén signalen gestuurd (anders zou elk moment als "vertrokken"
tellen). De menubalk laat dat dan zien met een knop om het te regelen.

Er wordt geen locatie opgevraagd, opgeslagen of verstuurd — alleen de naam van
het netwerk.

Zit je op een netwerk dat nog nergens bij hoort, dan toont het menu dat met
"(niet gekoppeld)" en kun je het ter plekke aan een klant hangen.

> Let op: de app wordt lokaal ad-hoc ondertekend. Na een herbouw kan macOS de
> toestemming opnieuw vragen.

## ControlPlane (optioneel, en momenteel stuk)

Het adaptercommando bestaat nog, zodat een extern programma dezelfde signalen
kan geven:

```bash
scripts/controlplane-event.sh start "Efteling-Guest"
scripts/controlplane-event.sh stop  "Efteling-Guest"
```

Het script faalt nooit richting de aanroeper; alles komt in
`~/Library/Logs/WifiHours-adapter.log`. Wat er verwerkt is, staat in
`wifihours events`.

**ControlPlane 2.0.0 werkt niet op macOS 26.** Het is gebouwd tegen de
macOS 10.6-SDK en crasht direct bij het opstarten:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
reason: '-[NSToolbarItem setAccessibilityLabel:]: unrecognized selector'
```

Daarom detecteert de app het wifinetwerk nu zelf. Wie ControlPlane (of iets
anders) tóch wil gebruiken, richt er per SSID een context mee in die bij
activeren en verlaten bovenstaand script aanroept met die SSID als parameter.

## Wat de tracker met een signaal doet

| Situatie | Gedrag |
| --- | --- |
| Onbekend wifinetwerk | niets automatisch, alleen een logregel |
| Geen toestemming voor Locatievoorzieningen | geen signalen; de menubalk vraagt erom |
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

## Automatische pauzeaftrek

Per klant in te stellen: hoeveel pauze er van een werkdag af gaat, en vanaf
hoeveel gewerkte uren dat geldt. Beide zijn los instelbaar; standaard staat de
regel uit.

```bash
wifihours break list
wifihours break set --profile "Efteling" --minutes 30 --threshold 6:00
wifihours break set --profile "Efteling" --enabled false
```

In de app: menubalk → **Pauze-instellingen…**

De regels:

- de aftrek geldt **per klant per dag**, niet per blok — pauzeer je tussendoor,
  dan wordt er nog steeds maar één keer afgetrokken;
- de drempel telt **inclusief**: staat hij op 6:00, dan gaat bij precies 6 uur de
  pauze er al af;
- onder de drempel gaat er niets af;
- er gaat nooit meer af dan er die dag gewerkt is, dus een dag wordt niet negatief.

Belangrijk: dit is een **rekenregel over de ruwe blokken heen**. Je
tijdregistraties worden er niet door aangepast, dus je kunt de regel altijd
aanpassen of uitzetten — ook met terugwerkende kracht. Dag-, week- en
maandtotalen, de menubalk en de export tonen netto; de verdeling per project
blijft bruto, omdat pauze aan een dag hangt en niet aan een project.

In de CSV-export komt de aftrek als een aparte regel met een negatieve duur
(`status = pauze`, `bron = regel`), zodat de duur-kolom optelt tot de netto
uren. Met `wifihours export --bruto` blijven alleen de ruwe blokken over.

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

**Projecten beheren…** (⌘P) opent een venster waarin je per organisatie
projecten toevoegt, hernummert, hernoemt, activeert of deactiveert, en het
actieve project kiest. Het eerste project van een organisatie wordt meteen het
actieve project — zonder actief project start de tracker namelijk niet
automatisch bij binnenkomst.

**Overzicht en correcties…** opent een venster met het dag-, week- of
maandoverzicht: totalen per project, alle blokken, het corrigeren van begin,
einde, project en notitie, blokken toevoegen of verwijderen, en CSV-export van de
getoonde periode.

## Opdrachtregel

```bash
wifihours status                 # ook --json
wifihours report week            # of day / month, met --date en --profile
wifihours break set --profile "Efteling" --minutes 30 --threshold 6:00
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
twee contexten tegelijk, meerdere wifinetwerken per klant, projectkoppeling,
-wissel en hernummeren, unieke projectnummers, automatische pauzeaftrek,
herstarten met een open timer, dag-/week-/maandtotalen en CSV-export, en draait
het echte adaptercommando als los proces.

De suite draait als gewoon programma en niet via `swift test`: XCTest en
swift-testing zitten alleen in de volledige Xcode, niet in de Command Line Tools.
Is Xcode geïnstalleerd, dan kunnen de checks één op één naar swift-testing.

## Handmatig te testen op de Mac

Dit deel vraagt om echte wifi en ControlPlane:

- binnenkomen bij een klant (start, juiste profiel, juiste project);
- vertrekken (stop na de wachttijd, juiste eindtijd);
- korte wifi-uitval (blok loopt door, geen tweede blok);
- roamen tussen twee netwerken van dezelfde klant (geen tweede blok);
- slaapstand over de nacht (blok wordt `open`, geen verzonnen einde);
- twee klanten kort na elkaar (waarschuwing, geen automatische stop);
- toestemming voor Locatievoorzieningen intrekken (geen valse stopsignalen).
