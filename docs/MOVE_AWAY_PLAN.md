# Move Away — Suunnitteludokumentti

## Tausta

Reaalimaailman pintakäsittelylinjassa on asemia,
joiden päälle tai kohdalle nostin ei saa jäädä idlenä:

- **Lastausasema**: Käyttäjän on päästävä asemalle lastaamaan/purkamaan.
  Nostin estää pääsyn.
- **Aggressiiviset kylvyt**: Höyry/roiskeet korrodoivat
  nostimen rakenteita. Nostin tulee ajaa pois mahdollisimman
  nopeasti tehtävän jälkeen.
- **Huuhteluasemat**: Vesi roisku nostimen päälle turhaan.

Nykyisessä toteutuksessa nostin jää Phase=0 (idle) viimeiselle
SinkStation-asemalle. Move Away lisää mekanismin, jolla nostin
siirretään automaattisesti turvalliseen paikkaan.

---

## Asemakonfiguraatio

### stations.json (Gateway / data)

Uusi kenttä per asema:

```json
{
  "station_id": 101,
  "name": "Loading",
  "move_away_s": 5,
  ...
}
```

| Kenttä | Tyyppi | Merkitys |
|--------|--------|----------|
| `move_away_s` | INT (s) | 0 = nostin saa jäädä. >0 = idle sallittu max tämän verran sekunteja, sitten nostin siirretään pois. |

### UDT_StationType (PLC)

Uusi kenttä:

```
MoveAway : INT;   (* 0 = no move-away, >0 = max idle time (s) before forced move *)
```

### OPC UA -kirjoitus (Gateway → PLC)

`opcua_nodes.js`: Lisätään `move_away` node per asema.
`opcua_adapter.js`: Kirjoitetaan `g_station[stn].MoveAway` konfiguraatiovaiheessa.

---

## PLC-toteutus

### Uusi funktio: STC_MoveAway

```
FUNCTION STC_MoveAway : BOOL
```

**Kutsupaikka**: TSK_FB_Scheduler, NTT-vaiheen (Phase 2200)
yhteydessä tai sen jälkeen (uusi phase 2202).

**Logiikka**:

```
FOR ti := 1 TO MAX_Transporters DO

  (* Vain idle-nostimet *)
  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status < 3 THEN CONTINUE; END_IF;

  stn := g_transporter[ti].CurrentStation;
  IF stn < MIN_StationIndex OR stn > MAX_StationIndex THEN CONTINUE; END_IF;

  move_away_s := g_station[stn].MoveAway;
  IF move_away_s = 0 THEN CONTINUE; END_IF;

  (* Laske idle-aika: kuinka kauan nostin on ollut tällä asemalla *)
  idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(move_away_s) THEN CONTINUE; END_IF;

  (* Idle-aika ylittynyt → aseta poissiirtotehtävä *)
  (* Kohde: lähimpään suuntaan seuraava asema, jolla MoveAway = 0 *)
  dest_stn := find_safe_station(ti, stn);
  IF dest_stn = 0 THEN CONTINUE; END_IF;

  (* Aseta FinalTarget ilman varsinaista task-tehtävää *)
  g_transporter[ti].XFinalTarget := g_station[dest_stn].XPosition;
  g_transporter[ti].Phase := 1;  (* to_source — SIM aloittaa ajon *)
  g_transporter[ti].SinkStationTarget := dest_stn;
  g_transporter[ti].LiftStationTarget := stn;

END_FOR;
```

### Kohteen valinta (find_safe_station)

Etsitään lähimpään suuntaan asema, jolla `MoveAway = 0`
ja joka on nostimen TWA-alueen sisällä:

1. Etsi molemmin puolin lähimmät asemat joilla MoveAway = 0
2. Valitse lähempi
3. Jos molemmat yhtä kaukana, suosi transporterin tulosuunnasta
   vastakkaista puolta (pois edelliseltä tehtävältä)

### IdleStartTime -seuranta

`UDT_JC_SimTransporterType` tarvitsee uuden kentän:
```
IdleStartTime : LINT;   (* unix timestamp when transporter became idle *)
```

Asetetaan `SIM_FB_RunTasks`:ssa kun Phase siirtyy 0:ksi:
```
IF g_transporter[ti].Phase = 0 AND prev_phase <> 0 THEN
  g_sim_trans[ti].IdleStartTime := g_time_s;
END_IF;
```

---

## SIM-tason toteutus

SIM_FB_RunTasks käsittelee jo Phase 1 (to_lift):
- X-ajaa kohti LiftStationTarget
- Kun perillä → Phase 2 (lifting)

Move Away -tilanteessa nostin ei nosta mitään (ei ole yksikköä).
Tarvitaan tunnistus: **Phase = 1 mutta ei varsinaista lift-tehtävää**.

Vaihtoehto A: Käytä Phase = 1 normaalisti, mutta
SIM_FB_RunTasks tarkistaa: jos nostimella ei ole yksikköä
nostettavaksi (UnitAtStation = 0), Phase 1:n jälkeen
siirry suoraan Phase 0 (idle) eikä Phase 2.

Vaihtoehto B: Uusi Phase-arvo (esim. Phase = 5 = move_away).
SIM käsittelee vain X-ajon, ei Z-liikettä. Perillä → Phase 0.

**Suositus**: Vaihtoehto B — erillinen Phase-arvo 5 on
selkeämpi eikä häiritse olemassa olevaa tehtävien käsittelyä.

### Phase 5: Move Away -ajo

```
(* Phase 5: Move Away — X-drive to safe position, no Z-motion *)
IF g_transporter[ti].Phase = 5 THEN
  (* X-drive towards FinalTarget *)
  fb_x(... x_target := g_transporter[ti].XFinalTarget ...);
  IF arrived_x THEN
    g_transporter[ti].Phase := 0;   (* idle at new position *)
    g_transporter[ti].CurrentStation := nearest_station;
    g_sim_trans[ti].IdleStartTime := g_time_s;
  END_IF;
END_IF;
```

Tällöin STC_MoveAway asettaa Phase := 5 (ei 1):

```
g_transporter[ti].Phase := 5;
g_transporter[ti].XFinalTarget := g_station[dest_stn].XPosition;
```

---

## Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| **UDT_StationType.st** | Lisää `MoveAway : INT` |
| **UDT_JC_SimTransporterType.st** | Lisää `IdleStartTime : LINT` |
| **STC_MoveAway.st** | Uusi funktio (idle-tarkistus + kohteen valinta) |
| **TSK_FB_Scheduler.st** | Kutsu `STC_MoveAway` phase 2200 jälkeen |
| **SIM_FB_RunTasks.st** | Phase 5 käsittely (X-ajo ilman Z-liikettä) |
| **SIM_FB_RunTasks.st** | IdleStartTime tallennus Phase 4→0 siirtymässä |
| **opcua_nodes.js** | `move_away` node per asema |
| **opcua_adapter.js** | Kirjoita `MoveAway` konfiguraatiossa |
| **stations.json** (kaikki templateit) | Lisää `move_away_s` per asema |

---

## Aikajärjestys

| Vaihe | Toimenpide |
|-------|-----------|
| 1 | UDT-muutokset (StationType + SimTransporterType) |
| 2 | STC_MoveAway funktio + TSK-integraatio |
| 3 | SIM_FB_RunTasks Phase 5 + IdleStartTime |
| 4 | Gateway: OPC UA node + adapter-kirjoitus |
| 5 | stations.json templateiden päivitys |
| 6 | Build + testaus |

---

## Avoimet kysymykset

1. **Kohteen valintasäännöt**: Lähimpään turvalliseen asemaan,
   vai aina tiettyyn "kotiasemaan"? Vai konfiguoitava?
2. **Move Away keskeytys**: Jos uusi tehtävä tulee Phase 5
   aikana, keskeytetäänkö move away välittömästi?
   → Kyllä, SIM_FB_RunTasks voi tarkistaa uuden task_id:n.
3. **Useita nostimia**: Jos kaksi nostinta on vierekkäisillä
   move_away-asemilla, kumpi väistää ensin?
   → Ensimmäinen FOR-loopissa. Törmäyksen esto on TWA:n vastuulla.
4. **Move Away ja NTT**: Voiko NTT-tehtävä tulla samaan aikaan
   kun move away on käynnissä? → Phase 5 ei ole Phase 0,
   joten NTT ei anna uutta tehtävää. Phase 5:n valmistuttua
   nostin on idle (Phase 0) turvallisella asemalla.
5. **Scheduler-yhteensopivuus**: DEP/TSK idle-slot-laskenta
   ei huomioi Phase 5 -ajoa. Tarvitaanko?
   → Todennäköisesti ei, koska move away on lyhyt ajo
   eikä siihen liity yksikön siirtoa.
