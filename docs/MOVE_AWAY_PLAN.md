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

**Kutsupaikka**: TSK_FB_Scheduler uudessa vaiheessa **2202**,
eli NTT:n (2200) ja APPLY_STRETCHES-vaiheen (2201) jälkeen,
ennen READY-vaihetta.

**Periaate**:

- Move away ei saa tehdä nostimesta "aktiivista tehtävää"
- Nostin pysyy edelleen `Phase = 0` tilassa
- Poissiirto on vain idlen sisäinen vapaaehtoinen X-siirto
- Jos oikea tehtävä ilmestyy kesken poissiirron, se ohittaa move awayn heti
- TWA:ssa move away -nostin on edelleen idle-luokassa, eli se ei saa aktiivisen
  tehtävän prioriteettia eikä aseta aktiivisen tehtävän prioriteettirajoja
- Idle-luokan sisällä move away -nostin on paikallaan olevaa idle-nostinta
  korkeammalla: paikallaan oleva idle väistää poissiirtyvää idleä
- Dynaamiset TWA-aluerajat ovat aina voimassa myös move away -ajossa: nostin ei saa
  ajaa niiden yli, mutta move awayta ei keskeytetä pelkästään siksi että rajat muuttuvat
- Move away -kohde asetetaan vain kerran per pyyntö; aktiivista poissiirtoa ei
  retargetoida joka scheduler-kierroksella

**Logiikka**:

```
FOR ti := 1 TO MAX_Transporters DO

  (* Vain idle-nostimet *)
  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status < 3 THEN CONTINUE; END_IF;
  IF g_transporter[ti].MoveAwayActive THEN CONTINUE; END_IF;

  stn := g_transporter[ti].CurrentStation;
  IF stn < MIN_StationIndex OR stn > MAX_StationIndex THEN CONTINUE; END_IF;

  move_away_s := g_station[stn].MoveAway;
  IF move_away_s = 0 THEN CONTINUE; END_IF;

  (* Laske idle-aika: kuinka kauan nostin on ollut tällä asemalla *)
  idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(move_away_s) THEN CONTINUE; END_IF;

  (* Idle-aika ylittynyt → laske poissiirtokohde *)
  current_x := g_transporter[ti].XPosition;

  IF g_task[ti].Count > 0 THEN
    (* Seuraava tehtävä jonossa → suunta kohti sen alkuasemaa *)
    next_lift_x := g_station[ g_task[ti].Queue[1].LiftStationTarget ].XPosition;
    IF next_lift_x > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  ELSE
    (* Ei seuraavaa tehtävää → suunta kohti ajoalueen keskikohtaa *)
    area_center := (g_cfg[ti].DrivePosMin + g_cfg[ti].DrivePosMax) / 2;
    IF area_center > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  END_IF;

  (* Etsi vähintään kahden asemavälin päässä oleva asema valittuun suuntaan.
     find_station_offset: ks. määrittely alla. *)
  dest_stn := find_station_offset(
    i_trans := ti,
    i_from_stn := stn,
    i_dir := dir,
    i_min_steps := 2
  );
  IF dest_stn = 0 THEN CONTINUE; END_IF;

  (* Jos kohdeasemalla on myös MoveAway, jatka samaan suuntaan yksi asema kerrallaan *)
  WHILE (dest_stn >= MIN_StationIndex) AND (dest_stn <= MAX_StationIndex)
        AND (g_station[dest_stn].MoveAway > 0) DO
    next_stn := find_station_offset(
      i_trans := ti,
      i_from_stn := dest_stn,
      i_dir := dir,
      i_min_steps := 1
    );

    (* Ei löytynyt enää uutta asemaa samaan suuntaan → ei aseteta move awayta *)
    IF (next_stn = 0) OR (next_stn = dest_stn) THEN
      dest_stn := 0;
      EXIT;
    END_IF;

    dest_stn := next_stn;
  END_WHILE;

  IF dest_stn = 0 THEN CONTINUE; END_IF;

  (* Aseta idle-moodissa toteutettava poissiirtopyyntö *)
  g_transporter[ti].MoveAwayActive := TRUE;
  g_transporter[ti].MoveAwayTargetStation := dest_stn;
  g_transporter[ti].MoveAwayTargetX := g_station[dest_stn].XPosition;

END_FOR;
```

### Kohteen valinta

Poissiirron kohde määräytyy kahdessa vaiheessa:

**1. Suunnan valinta**

Suunta valitaan kuten aiemmin:

- jos seuraava tehtävä jonossa (`g_task[ti].Count > 0`), suunta on kohti seuraavan tehtävän alkuasemaa (`Queue[1].LiftStationTarget`)
- jos seuraavaa tehtävää ei ole, suunta on kohti nostimen ajoalueen keskikohtaa

```
IF g_task[ti].Count > 0 THEN
  next_lift_x := g_station[ g_task[ti].Queue[1].LiftStationTarget ].XPosition;
  IF next_lift_x > current_x THEN
    dir := 1;
  ELSE
    dir := -1;
  END_IF;
ELSE
  area_center := (g_cfg[ti].DrivePosMin + g_cfg[ti].DrivePosMax) / 2;
  IF area_center > current_x THEN
    dir := 1;
  ELSE
    dir := -1;
  END_IF;
END_IF;
```

**2. Kohdeaseman valinta**

Kohde ei ole enää vapaa `target_x`-koordinaatti, vaan aina jonkin aseman
`XPosition`.

Perussääntö:

- lähtöasema on nykyinen asema `stn`
- valittuun suuntaan siirrytään **vähintään kahden asemavälin** päähän
- tämän aseman `XPosition` asetetaan `MoveAwayTargetX`:ksi

```
dest_stn := find_station_offset(
  i_trans := ti,
  i_from_stn := stn,
  i_dir := dir,
  i_min_steps := 2
);

IF dest_stn = 0 THEN
  CONTINUE;  (* ei löytynyt riittävän kaukana olevaa asemaa tähän suuntaan *)
END_IF;

g_transporter[ti].MoveAwayTargetX := g_station[dest_stn].XPosition;
```

Jos valitulla kohdeasemalla on myös `MoveAway > 0`, jatketaan samaan suuntaan
yksi asema kerrallaan, kunnes löytyy asema jolla `MoveAway = 0`.

```
WHILE g_station[dest_stn].MoveAway > 0 DO
  next_stn := find_station_offset(
    i_trans := ti,
    i_from_stn := dest_stn,
    i_dir := dir,
    i_min_steps := 1
  );

  IF (next_stn = 0) OR (next_stn = dest_stn) THEN
    dest_stn := 0;
    EXIT;
  END_IF;

  dest_stn := next_stn;
END_WHILE;
```

Näin poissiirto tapahtuu aina todelliselle asemalle, ei asemien väliin,
ja ketjutetut move away -asemat ohitetaan automaattisesti samaan suuntaan.

**Rajatapaus**: jos valittuun suuntaan ei löydy riittävän kaukaa asemaa
nostimen ajoalueelta, tai ketjutuksessa ei enää löydy uutta asemaa, poissiirtoa
ei aseteta lainkaan.

**MoveAwayTargetStation** on aina sama asema, jonka `XPosition`
kirjoitetaan `MoveAwayTargetX`:ksi.

### find_station_offset -apufunktio

Uusi funktio `STC_FindStationOffset` (tiedosto **STC_FindStationOffset.st**).

```
FUNCTION STC_FindStationOffset : INT   (* palauttaa station_number tai 0 *)
VAR_INPUT
  i_trans     : INT;   (* transporter index — ajoalueen rajaukseen *)
  i_from_stn  : INT;   (* lähtöasema *)
  i_dir       : INT;   (* +1 = oikealle (kasvava X), -1 = vasemmalle *)
  i_min_steps : INT;   (* vähintään näin monta asemaväliä *)
END_VAR
```

Toiminta:

1. Käy asemat X-suunnassa `i_dir`-suuntaan alkaen `i_from_stn` + 1 asemaväli
2. "Asemaväli" = seuraava asema X-positiojärjestyksessä nostimen linjalla
   (ei station_number-järjestyksessä, vaan g_station[stn].XPosition -vertailulla)
3. Ohita asemat joilla `TankId = 0`
4. Laske askeleet; kun `i_min_steps` täyttyy, palauta kyseinen asema
5. Jos aseman `XPosition` ylittää nostimen ajoalueen (`g_cfg[i_trans].DrivePosMin` /
   `DrivePosMax`), palauta 0
6. Jos asemia ei löydy riittävästi, palauta 0

### IdleStartTime -seuranta

`UDT_JC_SimTransporterType` tarvitsee uuden kentän:
```
IdleStartTime : LINT;   (* unix timestamp when transporter became idle *)
```

Asetetaan `SIM_FB_RunTasks`:ssa Phase 4→0 -siirtymän yhteydessä.
Nykyisessä SIM:ssä ei ole `prev_phase`-muuttujaa, joten tallennus
tehdään suoraan `arrived_z`-blokin sisällä ennen `Phase := 0` -asetusta:
```
IF arrived_z THEN
  ...
  g_sim_trans[i].IdleStartTime := g_time_s;   (* ← LISÄTTY *)
  g_transporter[i].Phase := 0;
  ...
END_IF;
```

Lisäksi tarvitaan initialisointi- ja resetointisäännöt, jotta move away ei laukea
väärin käynnistyksen tai keskeytyksen jälkeen:

- jos transporter on järjestelmän käynnistyessä jo `Phase = 0`, asetetaan
  `IdleStartTime := g_time_s`
- jos move away valmistuu, asetetaan `IdleStartTime := g_time_s`
- jos move away keskeytetään uuden oikean tehtävän vuoksi, `IdleStartTime`
  nollataan tai asetetaan uudelleen vasta kun transporter seuraavan kerran palaa idleen
- jos konfiguraatio tai runtime-tila alustetaan uudelleen, `MoveAwayActive := FALSE`
  ja `IdleStartTime := g_time_s`

### Uudet runtime-kentät

`UDT_TransporterStatusType` tarvitsee move awayn ajonaikaiset kentät:

```
MoveAwayActive        : BOOL;   (* idle move-away request active *)
MoveAwayTargetStation : INT;    (* safe station selected for idle move-away *)
MoveAwayTargetX       : DINT;   (* X target for idle move-away *)
```

Näitä ei käsitellä varsinaisena tehtävänä:
- `TaskId` ei muutu
- `Phase` ei muutu
- `LiftStationTarget` / `SinkStationTarget` eivät muutu

Näin uusi "oikea" tehtävä voidaan edelleen hyväksyä normaalilla Phase 0 -> 1
siirtymällä.

---

## SIM-tason toteutus

SIM_FB_RunTasks käsittelee jo Phase 0:n idle-haaran ja Phase 0 -> 1
tehtävän vastaanoton. Move away kannattaa toteuttaa tähän idle-haaraan,
ei uutena phasena.

### Idle-liike Phase 0:n sisällä

Nykyisessä SIM:ssä on Phase 0 -lohkon lopussa erillinen limit-clamp,
joka kutsuu `fb_x`:ää joka syklissä `x_target := current_x` pitääkseen
nostimen TWA-rajojen sisällä. Move away -ajo korvaa tämän clamp-kutsun
kun `MoveAwayActive = TRUE`: clamp-lohkoon lisätään ehto
`IF NOT g_transporter[i].MoveAwayActive THEN ... END_IF;`.

```
(* Phase 0: idle *)
IF g_transporter[ti].Phase = 0 THEN

  (* Oikea tehtävä voittaa aina move awayn *)
  IF g_transporter[ti].TaskId <> g_sim_trans[ti].RunningTaskId THEN
    g_transporter[ti].MoveAwayActive := FALSE;
    (* normaali Phase 0 -> 1 tehtävän vastaanotto *)

  ELSIF g_transporter[ti].MoveAwayActive THEN
    (* Idle move-away X-drive *)
    fb_x(...
      x_target := g_transporter[ti].MoveAwayTargetX,
      x_min    := g_transporter[ti].XMinDriveLimit,
      x_max    := g_transporter[ti].XMaxDriveLimit ...);

    IF arrived_x THEN
      g_transporter[ti].CurrentStation := g_transporter[ti].MoveAwayTargetStation;
      g_transporter[ti].MoveAwayActive := FALSE;
      g_sim_trans[ti].IdleStartTime := g_time_s;
    END_IF;
  END_IF;
END_IF;
```

Tämän mallin seuraukset:

- Nostin on koko ajan `Phase = 0`
- Uusi tehtävä voidaan hyväksyä heti kesken move awayn
- Move away ei tarvitse omaa task-rakennetta
- Move away ei vaikuta aktiivisen tehtävän prioriteettina TWA:ssa
- Move away noudattaa aina kulloinkin voimassa olevia dynaamisia X-rajoja

### Keskeytyssääntö

Move away keskeytetään vain, jos oikea tehtävä saadaan:

1. `TaskId` vaihtuu → oikea tehtävä saatu

Keskeytys ei ole virhetilanne. Nostin vain jää siihen kohtaan missä on,
ja normaali tehtäväohjaus jatkaa siitä.

Jos `MoveAwayTargetX` jää hetkellisesti TWA-limitien ulkopuolelle, move awayta ei
keskeytetä eikä kohdetta lasketa uudelleen. Nostin saa liikkua vain sen osan
matkasta, jonka dynaamiset rajat sallivat sillä hetkellä. Jos nostin on rajojen
ulkopuolella, normaali Phase 0 -rajojen kunnioitus palauttaa sen sallitulle alueelle.

Keskeytyksen jälkeen `MoveAwayActive := FALSE`. Uutta move away -kohdetta ei saa
laskea ennen kuin transporter on ollut taas idle-tilassa uuden `IdleStartTime`-
hetken verran.

### TWA-käyttäytyminen

Koska move away pitää nostimen edelleen `Phase = 0` tilassa:

- se ei saa Phase 1 / Phase 3 tehtäväprioriteettia
- se väistää aktiivisia nostimia
- muut nostimet voivat rajoittaa sitä normaalisti
- paikallaan oleva idle-nostin väistää poissiirtyvää idle-nostinta

Tämä täyttää vaatimuksen, että poissiirtyvä nostin on min/max
aluerajojen laskennassa edelleen idle-nostin, mutta idle-luokan sisällä
paikallaan olevaa idleä korkeammalla.

Prioriteettijärjestys on siis:

- paikallaan oleva idle
- poissiirtyvä idle
- aktiivinen tehtävä

Jos kaksi nostinta yrittää move awayta samaan aikaan, ne ovat samalla
move-away-idle-tasolla. Tällöin eteneminen määräytyy normaalien TWA-rajojen
ja turvavälien perusteella.

---

## Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| **UDT_StationType.st** | Lisää `MoveAway : INT` |
| **UDT_JC_SimTransporterType.st** | Lisää `IdleStartTime : LINT` |
| **UDT_TransporterStatusType.st** | Lisää `MoveAwayActive`, `MoveAwayTargetStation`, `MoveAwayTargetX` |
| **STC_MoveAway.st** | Uusi funktio (idle-tarkistus + kohteen valinta) |
| **STC_FindStationOffset.st** | Uusi funktio (asemahaku X-suuntaan min_steps askelin) |
| **TSK_FB_Scheduler.st** | Lisää uusi vaihe 2202, kutsu `STC_MoveAway` siinä. **Huom:** vaiheen 2201 nykyinen `next_phase := 10000` muutetaan pois, jotta oletusarvoinen `phase + 1` siirtyy vaiheeseen 2202. |
| **SIM_FB_RunTasks.st** | Idle-haaran move away -ajo + välitön keskeytys oikealle tehtävälle |
| **SIM_FB_RunTasks.st** | IdleStartTime tallennus Phase 4→0 `arrived_z`-lohkossa, käynnistysinitialisointi, move awayn valmistuessa. Idle-clamp -lohkoon `IF NOT MoveAwayActive` -suoja. |
| **opcua_nodes.js** | `move_away` node per asema |
| **opcua_adapter.js** | Kirjoita `MoveAway` konfiguraatiossa |
| **stations.json** (kaikki templateit) | Lisää `move_away_s` per asema |

**Huomio UI:lle**: nostin näkyy UI:ssa idle-tilassa myös move awayn aikana.
Jos halutaan visuaalinen ilmaisin, UI:n pitää lukea `MoveAwayActive`
OPC UA:lla tai eventillä. Tämä ei ole pakollinen ensimmäisessä versiossa.

---

## Aikajärjestys

| Vaihe | Toimenpide |
|-------|-----------|
| 1 | UDT-muutokset (StationType + SimTransporterType) |
| 2 | STC_FindStationOffset apufunktio |
| 3 | STC_MoveAway funktio + uusi scheduler phase 2202 |
| 4 | SIM_FB_RunTasks idle move-away + IdleStartTime + idle-clamp suoja |
| 5 | Gateway: OPC UA node + adapter-kirjoitus |
| 6 | stations.json templateiden päivitys |
| 7 | Build + testaus |

---

## Avoimet kysymykset

1. **Kohteen valintasäännöt**: ~~Lähimpään turvalliseen asemaan,
   vai aina tiettyyn "kotiasemaan"? Vai konfiguoitava?~~
   → Ratkaistu: Suunta valitaan kuten aiemmin. Kohde on aina asema,
   vähintään kahden asemavälin päässä valittuun suuntaan.
2. **Move Away keskeytys**: Jos uusi tehtävä tulee kesken
  move awayn, keskeytetäänkö move away välittömästi?
  → Kyllä. Tämä on suunnittelun perusvaatimus.
3. **Useita nostimia**: Jos kaksi nostinta on vierekkäisillä
   move_away-asemilla, kumpi väistää ensin?
  → Paikallaan oleva idle väistää poissiirtyvää idleä. Jos molemmat ovat
  poissiirtyviä idlejä, eteneminen määräytyy TWA-rajojen ja turvavälien perusteella.
4. **Move Away ja NTT**: Voiko NTT-tehtävä tulla samaan aikaan
  kun move away on käynnissä? → Kyllä, koska nostin on edelleen
  `Phase = 0`. NTT/TSK voivat antaa oikean tehtävän, jolloin
  move away keskeytetään heti.
5. **Scheduler-yhteensopivuus**: DEP/TSK idle-slot-laskenta
  ei huomioi move away -ajoa eksplisiittisesti. Tarvitaanko?
  → Todennäköisesti ei, jos move away pysyy aidosti vapaaehtoisena
  idle-liikkeenä ja se voidaan keskeyttää heti oikean tehtävän tieltä.

6. **Kohdeaseman ketjutus**: Jos vähintään kahden asemavälin päässä
  oleva kohdeasema on myös `MoveAway`-asema, jatketaanko samaan suuntaan?
  → Kyllä. Kohdeasemaa siirretään yksi asema kerrallaan samaan suuntaan,
  kunnes löytyy asema jolla `MoveAway = 0`.

7. **Ketjutuksen rajatapaus**: Mitä tehdään jos samaan suuntaan ei löydy enää
  uutta asemaa tai `find_station_offset` ei pysty etenemään?
  → Move awayta ei aseteta lainkaan. Funktiolla on oltava eksplisiittinen
  katkaisuehto tälle tilanteelle.
