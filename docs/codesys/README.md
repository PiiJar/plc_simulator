# CODESYS Scheduler — Kehittäjädokumentaatio

Tämä dokumentaatio kattaa pintakäsittelylinjan scheduler-kirjaston lähdekoodin (IEC 61131-3 Structured Text).
Dokumentaatio on tarkoitettu kirjaston kehitystiimille — ei loppuasiakkaille.

## Toimitusraja

Ohjelmisto jaetaan kahteen osaan:

```
LUKITTU KIRJASTO (salataan projektitoimituksissa)
┌──────────────────────────────────────────────┐
│  STC_FB_MainScheduler    ← kirjaston entry point │
│  TSK_*, DEP_*, STC_*, TWA_*                  │
│  GVL_JC_Constants, GVL_JC_Scheduler          │
│  UDT_* (kaikki tietotyypit)                  │
└──────────────────────────────────────────────┘

KEHITYSYMPÄRISTÖ (ei toimiteta asiakkaalle)
┌──────────────────────────────────────────────┐
│  PLC_PRG (testi-integraatio)                 │
│  SIM_* (fysiikkasimulaatio, tapahtumajonot)  │
│  GVL_Parameters (testidata)                  │
│  Docker-infra, Gateway, UI                   │
└──────────────────────────────────────────────┘
```

Asiakas saa kirjaston CODESYS-kirjastona (**Library**), jossa lähdekoodi on lukittu.
Asiakas integroi kirjaston omaan PLC_PRG-ohjelmaansa kutsumalla `STC_FB_MainScheduler`-instanssia
ja kirjoittamalla konfiguraatiodata globaaleihin muuttujiin (ks. [DATA_MODEL.md](DATA_MODEL.md)).

## Dokumenttirakenne

| Dokumentti | Sisältö |
|------------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Kokonaiskuva: kerrosarkkitehtuuri, suoritusvirta, komponenttien vastuut |
| [SCHEDULER_PHASES.md](SCHEDULER_PHASES.md) | TSK- ja DEP-tilakone vaiheineen, transitiot, suoritusjärjestys |
| [CONFLICT_RESOLUTION.md](CONFLICT_RESOLUTION.md) | Analyze → Resolve -silmukka, strategiat, lukitusmekanismi |
| [DEP_SCHEDULER.md](DEP_SCHEDULER.md) | Departure scheduler: sandbox-malli, idle slot -sovitus, aktivointi |
| [DATA_MODEL.md](DATA_MODEL.md) | GVL-rakenteet, UDT-tyypit, tietovirta Gateway ↔ PLC |
| [SIMULATION.md](SIMULATION.md) | SIM-kerros: fysiikkamallinnus, tapahtumageneraatio (vain kehitysympäristö) |
| [BUILD_AND_DEPLOY.md](BUILD_AND_DEPLOY.md) | build_codesys_xml.py, PLCopenXML-generointi, kirjaston paketointi |
| [MODULE_REFERENCE.md](MODULE_REFERENCE.md) | Tiedostokohtainen referenssi: POU-tyyppi, rajapinta, riippuvuudet |

## Lukujärjestys

Uudelle kehittäjälle suositeltava järjestys:

1. **ARCHITECTURE** — kokonaiskuva ja suoritusvirta
2. **DATA_MODEL** — tietorakenteet ennen logiikkaan syventymistä
3. **SCHEDULER_PHASES** — varsinainen laskentaketju
4. **CONFLICT_RESOLUTION** — schedulerin monimutkaisin osa
5. **DEP_SCHEDULER** — odottavien erien optimointi
6. **SIMULATION** — vain jos kehitetään kehitysympäristön simulaatiokerrosta (ei osa toimitettavaa kirjastoa)
7. **MODULE_REFERENCE** — hakuteoksena työn lomassa

## Termistö

| Termi | Selitys |
|-------|---------|
| **Unit** | Nostolaite (lifting frame / hook), kuljettaa tuotetta altaasta toiseen |
| **Transporter** | Nosturi (hoist), liikuttaa unit-elementtejä X/Z-suunnassa |
| **Station** | Käsittelyasema (allas), indeksoitu MIN_StationIndex..MAX_StationIndex |
| **Batch** | Tuotantoerä, sidottu yhteen unitiin ja käsittelyohjelmaan |
| **Treatment Program** | Vaiheketju (stage 0..N), jokaisella min/cal/max-aika ja kohdeasemat |
| **Task** | Yksittäinen siirtotehtävä: nosta asemalta A, laske asemalle B |
| **TSK** | Task Scheduler — aktiivisten erien laskenta ja konfliktiratkaisu |
| **DEP** | Departure Scheduler — odottavien erien sovitus tuotantoon |
| **NTT** | No-Treatment Task — siirto ilman käsittelyä (puskuri, purku, väistö) |
| **TWA** | Transporter Working Area — X-alueen törmäyksenesto |
| **STC** | Scheduler Tool Collection — jaetut laskentafunktiot |
| **SIM** | Simulation — fysiikkamallinnus ja tapahtumagenerointi |
