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

### Datan lähde: asiakkaan laitoskonfiguraatio

Poissiirtotieto on osa asiakkaan laitoskohtaista asemakonfiguraatiota.
Datapolku järjestelmässä:

```
data/customers/<Asiakas>/<Laitos>/stations.json   ← lähde (käyttäjän konfiguroima)
  → Gateway lukee käynnistyksessä
    → OPC UA write: Stations[stn].MoveAway
      → PLC käyttää STC_MoveAway-funktiossa
```

Käytännössä Gateway lukee `stations.json`-tiedoston `move_away`-kentän ja
kirjoittaa sen OPC UA:n kautta PLC:n `Stations[stn].MoveAway`-kenttään
samalla kun muukin asemakonfiguraatio (XPosition, DeviceDelay, jne.) lähetetään.

### stations.json -kenttä

Uusi kenttä per asema:

```json
{
  "number": 101,
  "name": "Loading/Unloading",
  "move_away": 5,
  ...
}
```

Oikea esimerkki: `data/customers/Nammo Lapua Oy/Factory X Zinc Phosphating/stations.json`,
asema 101 (Loading/Unloading):
```json
{
  "number": 101,
  "tank": 101,
  "group": 101,
  "name": "Loading/Unloading",
  "x_position": 100,
  "y_position": 0,
  "z_position": 0,
  "dropping_time": 0,
  "kind": 0,
  "operation": 42,
  "device_delay": 0.0,
  "move_away": 5,
  "start_station": true
}
```

| Kenttä | Tyyppi | Merkitys |
|--------|--------|----------|
| `move_away` | INT (s) | 0 = nostin saa jäädä. >0 = idle sallittu max tämän verran sekunteja, sitten nostin siirretään pois. |

### UDT_StationType (PLC)

Uusi kenttä:

```
MoveAway : INT;   (* 0 = no move-away, >0 = max idle time (s) before forced move *)
```

### OPC UA -kirjoitus (Gateway → PLC)

`opcua_nodes.js`: Lisätään `move_away` node per asema.
`opcua_adapter.js`: Kirjoitetaan `Stations[stn].MoveAway` konfiguraatiovaiheessa.

---

## PLC-toteutus

### Move Away: Status 3 & Phase 1

Poissiirto käyttää yhdistelmää **Status = 3 (Auto Idle)** ja **Phase = 1 (Siirto)**.
Tämä erottaa poissiirron selkeästi oikeista tuotantotehtävistä (joissa Status = 4),
mutta antaa PLC:n ymmärtää luonnollisesti, että nostin on liikkeessä.

### Uusi funktio: STC_MoveAway

```
FUNCTION STC_MoveAway : BOOL
```

**Kutsupaikka**: TSK_FB_Scheduler uudessa vaiheessa **2202**,
eli NTT:n (2200) ja APPLY_STRETCHES-vaiheen (2201) jälkeen,
ennen READY-vaihetta.

**Periaate**:

- Move away käyttää tilaa `Phase = 1` ja `Status = 3`
- Move away ei saa tehdä nostimesta "aktiivista tuotantotehtävää" (Status = 4)
- Poissiirto saa vaikuttaa seuraavan oikean tehtävän dispatch-aikalaskentaan:
  nostimen senhetkinen sijainti on tarkoituksella uusi lähtöpiste
- Jos oikea tehtävä ilmestyy kesken poissiirron, `STC_DispatchTask` keskeyttää sen heti
  asettamalla uuden kohteen ja muuttamalla tilaksi `Status = 4`
- TWA:ssa poissiirto (Status = 3, Phase = 1) sijoittuu prioriteetissa paikallaan seisovan idlen (Phase = 0)
  ja aktiivisen ajon (Status = 4) väliin.
- TWA:n passi 2 prioriteettivertailu käyttää Status/Phase-tietoa ohjaamaan rajoituksia oikein.
- **60 sekunnin sääntö**: Jos nostimen oma seuraava tehtävä alkaa täsmälleen siltä asemalta missä se on nyt,
  ja tehtävän alkuun on alle 60 sekuntia, poissiirtoa ei käynnistetä, vaan nostin odottaa paikallaan.

**Logiikka**:

```
FOR ti := 1 TO MAX_Transporters DO

  (* Vain idle-nostimet: tila 0 *)
  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;

  stn := g_transporter[ti].CurrentStation;
  IF stn < MIN_StationIndex OR stn > MAX_StationIndex THEN CONTINUE; END_IF;

  move_away := Stations[stn].MoveAway;
  IF move_away = 0 THEN CONTINUE; END_IF;

  (* Laske idle-aika: aika edellisen aktiivisen tehtävän päättymisestä *)
  idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(move_away) THEN CONTINUE; END_IF;

  (* 60 sekunnin sääntö: Älä siirry jos oma tehtävä alkaa pian tältä asemalta *)
  IF g_task[ti].Count > 0 THEN
      next_task_stn := g_task[ti].Queue[1].LiftStationTarget;
      IF next_task_stn = stn THEN
          time_to_start := g_task[ti].Queue[1].PlannedStartTime - i_time_s;
          IF time_to_start < g_MoveAway_MinWait_s THEN 
              CONTINUE; 
          END_IF;
      END_IF;
  END_IF;

  (* Idle-aika ylittynyt → laske poissiirtokohde *)
  current_x := g_transporter[ti].XPosition;

  IF g_task[ti].Count > 0 THEN
    (* Seuraava tehtävä jonossa → suunta kohti sen alkuasemaa *)
    next_lift_x := Stations[ g_task[ti].Queue[1].LiftStationTarget ].XPosition;
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

  (* Etsi vähintään kahden asemavälin päässä oleva asema valittuun suuntaan. *)
  dest_stn := find_station_offset(
    i_trans := ti,
    i_from_stn := stn,
    i_dir := dir,
    i_min_steps := 2
  );
  
  (* Jos osuttiin reunaan ilman tulosta, kokeillaan toiseen suuntaan *)
  IF dest_stn = 0 THEN 
    dir := -dir;
    dest_stn := find_station_offset(
      i_trans := ti,
      i_from_stn := stn,
      i_dir := dir,
      i_min_steps := 2
    );
    IF dest_stn = 0 THEN CONTINUE; END_IF;
  END_IF;

  (* Jos kohdeasemalla on myös MoveAway, jatka samaan suuntaan yksi asema kerrallaan *)
  WHILE (dest_stn >= MIN_StationIndex) AND (dest_stn <= MAX_StationIndex)
        AND (Stations[dest_stn].MoveAway > 0) DO
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
  g_transporter[ti].Phase := 1;
  g_transporter[ti].Status := 3;
  g_transporter[ti].LiftStationTarget := dest_stn;

END_FOR;
```

### Vaikutus dispatch-aikalaskentaan

Move away ei ole vain turvasiirto, vaan myös idle-aikainen ennakkopositiointi.

- `g_transporter[ti].CurrentStation` saa muuttua move awayn aikana normaalisti
  lähimmän aseman mukaan
- `STC_DispatchTask` saa käyttää tätä sijaintia seuraavan tehtävän travel-ajan
  laskentaan
- tämä on tarkoituksellinen ominaisuus, ei sivuvaikutus

Seuraukset:

- jos poissiirtosuunta on kohti jonossa olevaa ensimmäistä tehtävää,
  ensimmäisen tehtävän vasteaika yleensä paranee
- jos tehtäväjono on tyhjä ja suunta valitaan ajoalueen keskelle,
  move away optimoi ensisijaisesti turvallisuutta eikä välttämättä seuraavan
  tuntemattoman tehtävän vasteaikaa

Kun `g_task[ti].Count > 0`, move away toimii siis käytännössä myös
ennakkopositiointina kohti `Queue[1].LiftStationTarget`-asemaa.

### Kohteen valinta

Poissiirron kohde määräytyy kahdessa vaiheessa:

**1. Suunnan valinta**

Suunta valitaan kuten aiemmin:

- jos seuraava tehtävä jonossa (`g_task[ti].Count > 0`), suunta on kohti seuraavan tehtävän alkuasemaa (`Queue[1].LiftStationTarget`)
- jos seuraavaa tehtävää ei ole, suunta on kohti nostimen ajoalueen keskikohtaa

```
IF g_task[ti].Count > 0 THEN
  next_lift_x := Stations[ g_task[ti].Queue[1].LiftStationTarget ].XPosition;
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
  dir := -dir;
  dest_stn := find_station_offset(
    i_trans := ti,
    i_from_stn := stn,
    i_dir := dir,
    i_min_steps := 2
  );
  IF dest_stn = 0 THEN CONTINUE; END_IF;
END_IF;

g_transporter[ti].Phase := 1;
g_transporter[ti].Status := 3;
g_transporter[ti].LiftStationTarget := dest_stn;
```

Jos valitulla kohdeasemalla on myös `MoveAway > 0`, jatketaan samaan suuntaan
yksi asema kerrallaan, kunnes löytyy asema jolla `MoveAway = 0`.

```
WHILE Stations[dest_stn].MoveAway > 0 DO
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
2. "Asemaväli" = seuraava asema X-positiojärjestyksessä saman transporterin
  käyttöalueella
3. Käyttöalue määritellään `g_cfg[i_trans].TaskArea[]`-rajoista, ei pelkästä
  station-numerosta eikä pelkästä X-järjestyksestä
4. Ohita asemat joilla `TankId = 0`
5. Laske askeleet; kun `i_min_steps` täyttyy, palauta kyseinen asema
6. Jos aseman `XPosition` ylittää nostimen ajoalueen (`g_cfg[i_trans].DrivePosMin` /
  `DrivePosMax`), palauta 0
7. Jos asemia ei löydy riittävästi, palauta 0

Tarkennus:

- `STC_FindStationOffset` ei saa valita kohdeasemaa transporterin task area
  -rajojen ulkopuolelta
- monilinjaympäristössä "sama linja" määräytyy käytännössä saman transporterin
  sallittujen lift/sink-alueiden perusteella
- jos useita asemia on samalla tai lähes samalla X-koordinaatilla eri linjoilla,
  vain task area -rajoihin sopivat asemat osallistuvat hakuun

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

Käytännön toteutuspaikat nykyisessä järjestelmässä:

- `PLC_PRG` init-polku (`cmd=2`) asettaa alkuarvot käytössä oleville nostimille
- `SIM_FB_ClearConfig` nollaa kaikki move away -kentät clear-komennolla (`cmd=3`)
- `SIM_FB_RunTasks` asettaa `IdleStartTime := g_time_s`, kun oikea tehtävä päättyy
  ja transporter palaa `Phase = 0` tilaan
- `SIM_FB_RunTasks` asettaa `IdleStartTime := g_time_s`, kun move away valmistuu
- jos oikea tehtävä keskeyttää move awayn, `MoveAwayActive := FALSE` heti,
  mutta `IdleStartTime` asetetaan uudelleen vasta kun transporter seuraavan kerran
  palaa oikean tehtävän jälkeen idleen

### Uudet runtime-kentät

`Status = 3` ja `Phase = 1` -yhdistelmä korvaa erilliset move away -kentät.
Erillisiä `MoveAwayActive`, `MoveAwayTargetStation` tai `MoveAwayTargetX` kenttiä
**ei lisätä** UDT_TransporterStatusType:hen.

Poissiirto-tilan tunnistus:
- `Status = 3` ja `Phase = 1` → poissiirto käynnissä
- `Status = 3` ja `Phase = 0` → idle, ei poissiirtoa
- `Status = 4` ja `Phase = 1` → oikea tuotantotehtävä

Kohdeasema on `LiftStationTarget`, joka asetetaan normaalisti `STC_MoveAway`:ssa.
Kohde-X saadaan suoraan `Stations[LiftStationTarget].XPosition`.

---

## SIM-tason toteutus

`SIM_FB_RunTasks` ei tarvitse uutta X-drive blokia, vaan käytämme suorituksessa jo olemassa olevaa Phase 1 ajologiikkaa. Tässä on kaksi tehtävää muutosta:

1. Estetään `Phase = 1` siirtymästä laskuvaiheeseen `Phase = 2`, kun on kyse poissiirrosta:
```pascal
(* Phase 1: siirto nostoasemalle... kun at_target on TRUE *)
IF arrived_x AND arrived_y THEN
  IF g_transporter[i].Status = 3 THEN
      (* Tämä oli vain idle poissiirto, jäädään lepäämään turvalliselle asemalle *)
      g_transporter[i].Phase := 0;
      g_sim_trans[i].IdleStartTime := g_time_s;
  ELSE
      (* Oikea tehtävä jatkaa noston aloittamiseen *)
      g_transporter[i].Phase := 2;
  END_IF;
END_IF;
```

2. `Phase = 0` tarvitsee vain normaalin paikallaanpitoclampin, emmekä lisää sinne uusia Move Away -ajolohkoja. Nostin siirtyy kohteeseen käyttäen normaalia `Phase 1` X-ohjausta (`fb_x1`, `fb_x2`).

### TWA-käyttäytyminen

Koska move away asettaa nostimen `Phase = 1` tilaan, TWA (`TWA_FB_CalcLimits`) käsittelisi sitä oletuksena kriittisenä ajo-operaationa (prioriteetti yli 100000).
Jotta idle poissiirto väistää oikeita tehtäviä, mutta työntää paikallaan olevia nostimia pois edestään, TWA-prioriteettilogiikka pitää haarauttaa Status-tiedon perusteella:

```pascal
(* TWA_FB_CalcLimits_v2 *)
IF Phase = 1 THEN
    IF Status = 3 THEN
        Priority := 2; (* Poissiirto: väistää oikeita tehtäviä, mutta voittaa paikallaan seisovat *)
    ELSE
        Priority := 100000 + (eri laskennat); (* Oikea tuotantoajo *)
    END_IF;
ELSIF Phase = 0 THEN
    Priority := 1; (* Paikallaan makaava idle nollijää alin prioriteetiksi *)
END_IF;
```

Lisäksi TWA:n pass 2 "iso blokkeri" (`IF i_phase <> 0 THEN`) pitää korvata rakenteella `IF (i_phase <> 0) OR (i_status = 3 AND i_phase = 1) THEN`, jotta se ottaa poissiirrot mukaan alueiden turvalaskentaan.

### Dispatcherin (`STC_DispatchTask`) päivitys
Jotta poissiirron aikana nostin pysyy täysin dispatchattavana oikeaan tehtävään, `STC_DispatchTask`:n on ymmärrettävä uusi poissiirto-tila vapaana nostimena:
- Haku: Vapaina nostimina ymmärretään nyt joko täysin vapaa `(Phase = 0)` TAI poissiirtyvä vapaa `(Phase = 1 AND Status = 3)`.
- Reititys: Jos tällaiselle nostimelle annetaan oikea poimintatehtävä, järjestelmä lennosta muuttaa vain `Status := 4` (ja uuden taskin tiedot, esim `LiftStationTarget`). Nostin jatkaa vaivattomasti suoraan oikeaan työhön pysähtymättä välissä.

Tämän dokumentin arkkitehtuuri on nyt täysin linjassa olemassa olevan PLC- ja gateway-arkkitehtuurin kanssa. Välttämättömät muutokset on yksilöity ja eristetty kunkin asianomaisten järjestelmäkomponenttien sisään.
- aktiivinen tehtävä saa rajoittaa molempia idle-tiloja
- poissiirtyvä idle ei saa rajoittaa aktiivista tehtävää

Jos kaksi nostinta yrittää move awayta samaan aikaan, ne ovat samalla
move-away-idle-tasolla. Tällöin eteneminen määräytyy normaalien TWA-rajojen
ja turvavälien perusteella.

Tasatilanteessa ei lisätä erillistä move-away-voittajaa. Käyttäytyminen määräytyy:

- normaalin turvavälilogiikan
- olemassa olevan ID-pohjaisen tasatilanteen ratkaisun
- ja dynaamisten min/max-aluerajojen perusteella

Tavoite ei ole antaa move awaylle omaa "aktiivisen tehtävän" voittaja-asemaa,
vaan vain nostaa se paikallaan olevan idlen yläpuolelle.

### UI / observability

Erillisiä UI-muutoksia ei tarvita ensimmäiseen toteutusversioon.

Perustelu:

- nykyinen UI näyttää jo nostimien sijainnin ja liikkeen
- move away näkyy käyttäjälle nostimen X-sijainnin muutoksena
- toteutus voidaan validoida ilman erillistä move-away-badge- tai state-näkymää

Mahdollinen myöhempi parannus voi lisätä näkyviin `MoveAwayActive`-tilan,
mutta se ei ole toteutuksen edellytys.

---

## Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| **UDT_StationType.st** | Lisää `MoveAway : INT` |
| **UDT_JC_SimTransporterType.st** | Lisää `IdleStartTime : LINT` |
| **GVL_JC_Constants.st** | Lisää `g_MoveAway_MinWait_s : LINT := 60` |
| **STC_FindStationOffset.st** | Uusi funktio (asemahaku X-suuntaan min_steps askelin) |
| **STC_MoveAway.st** | Uusi funktio (idle-tarkistus + kohteen valinta + Phase/Status asetus) |
| **TSK_FB_Scheduler.st** | Lisää vaihe 2202, kutsu `STC_MoveAway`. Vaiheen 2201 `next_phase := 10000` → poistetaan. |
| **SIM_FB_RunTasks.st** | Phase 1 saapumislohko: Status=3 → Phase:=0 (ei Z-nostoa). IdleStartTime tallennus Phase 4→0 ja poissiirron valmistumisessa. |
| **TWA_FB_CalcLimits.st** | Prioriteettihaarautus: Status=3 & Phase=1 → priority 2 (idle-luokan ylempi). Pass 2 blokkerin ehtomuutos. |
| **STC_DispatchTask.st** | Vapaan nostimen haku: Phase=0 TAI (Phase=1 AND Status=3). Oikean tehtävän asetus: Status:=4. |
| **PLC_PRG.st** | Init (cmd=2): `IdleStartTime := g_time_s` käytössä oleville nostimille |
| **SIM_FB_ClearConfig.st** | Clear (cmd=3): Phase:=0, Status:=3, IdleStartTime:=g_time_s |
| **opcua_nodes.js** | `move_away` node per asema stationWrite()-funktioon |
| **opcua_adapter.js** | Kirjoita `Stations[stn].MoveAway` konfiguraatiossa |
| **stations.json** (kaikki templateit) | Lisää `move_away: 0` per asema |

**Huomio UI:lle**: nostin näkyy UI:ssa idle-tilassa (Status=3) myös move awayn aikana,
mutta Phase=1 näkyy siirtymätilana. Erillistä badge-toteutusta ei tarvita V1:ssä.

---

## Etenemissuunnitelma

Toteutus etenee neljässä vaiheessa. Jokainen vaihe on itsenäisesti buildattava
ja testattava kokonaisuus. Vaiheet rakennetaan yksi kerrallaan ja validoidaan
ennen seuraavaan siirtymistä.

### Vaihe 1: Tietorakenteet ja apufunktiot (peruselementit)

Tämä vaihe luo kaikki uudet tietorakenteet ja apufunktiot, mutta ei vielä
kutsu niitä mistään. Nykyinen järjestelmä toimii tämän vaiheen jälkeen
identtisesti kuin ennenkin.

| Askel | Tiedosto | Toimenpide | Rivit (nyk.) |
|-------|----------|------------|--------------|
| 1.1 | `UDTs/UDT_StationType.st` | Lisää `MoveAway : INT;` kentän loppuun | 33 |
| 1.2 | `UDTs/UDT_JC_SimTransporterType.st` | Lisää `IdleStartTime : LINT;` kentän loppuun | 16 |
| 1.3 | `GVLs/GVL_JC_Constants.st` | Lisää `g_MoveAway_MinWait_s : LINT := 60;` vakioksi | 74 |
| 1.4 | `POUs/STC_FindStationOffset.st` | Uusi tiedosto: asemahaku task area -rajojen sisällä | — |
| 1.5 | `POUs/STC_MoveAway.st` | Uusi tiedosto: idle-tarkistus, 60s sääntö, suunta, kohde, Phase/Status-asetus | — |

**Validointi V1:**
- `python3 build_codesys_xml.py` → buildaa onnistuneesti ilman virheitä
- Tuotettu XML sisältää uudet UDT-kentät, uudet POU:t ja uudet GVL-vakiot
- CODESYS IDE: Import XML → kompiloi → varmista ettei virheitä
- Nykyinen konfiguraatio pysyy ennallaan koska mitään ei kutsuta vielä

### Vaihe 2: PLC-integraatio (kutsuketju + SIM + TWA)

Tämä vaihe kytkee move awayn PLC:n ohjausketjuun. Vaiheen jälkeen
move away toimii PLC:ssä, mutta Gateway ei vielä kirjoita `MoveAway`-arvoja
asemille (joten kaikki `Stations[stn].MoveAway = 0` → mitään ei tapahdu).

| Askel | Tiedosto | Toimenpide | Rivit (nyk.) |
|-------|----------|------------|--------------|
| 2.1 | `POUs/TSK_FB_Scheduler.st` | Vaiheen 2201 `next_phase := 10000` poisto + vaihe 2202 lisäys kutsuen `STC_MoveAway` | 456 |
| 2.2 | `POUs/SIM/SIM_FB_RunTasks.st` | Phase 1 saapumislohko (~rivi 157): lisää `IF Status = 3 THEN Phase := 0; IdleStartTime := g_time_s; ELSE Phase := 2; END_IF;` | 609 |
| 2.3 | `POUs/SIM/SIM_FB_RunTasks.st` | Phase 4→0 siirtymä (~rivi 570): lisää `g_sim_trans[i].IdleStartTime := g_time_s;` ennen `Phase := 0` | 609 |
| 2.4 | `POUs/TWA_FB_CalcLimits.st` | Prioriteettilaskenta (~rivi 231): Status=3 & Phase=1 → priority := 2, Phase=0 → priority := 1 | 435 |
| 2.5 | `POUs/TWA_FB_CalcLimits.st` | Pass 2 blokkerin ehto (~rivi 306): `IF i_phase <> 0 THEN` → `IF (i_phase <> 0) OR (i_status = 3 AND i_phase = 1) THEN` | 435 |
| 2.6 | `POUs/STC_DispatchTask.st` | Vapaan nostimen haku (~rivi 140): lisää `OR (Phase = 1 AND Status = 3)` vapaa-ehtoon. Kun tehtävä annetaan: `Status := 4`. | 377 |
| 2.7 | `POUs/PLC_PRG.st` | Init cmd=2 (~rivi 52): lisää `g_sim_trans[ti].IdleStartTime := g_time_s;` | 189 |
| 2.8 | `POUs/SIM/SIM_FB_ClearConfig.st` | Clear cmd=3 (~rivi 65): lisää `g_sim_trans[ti].IdleStartTime := g_time_s;` | 223 |

**Validointi V2:**
- `python3 build_codesys_xml.py` → buildaa onnistuneesti
- CODESYS Import → Compile → 0 errors
- `docker compose restart codesys` + Gateway init (cmd=2):
  - Nostimet käynnistyvät normaalisti, koska `Stations[].MoveAway = 0` kaikkialla
  - Scheduler-kierros etenee vaiheiden 2200 → 2201 → 2202 → 10000 läpi (uusi vaihe ei tee mitään koska MoveAway=0)
- Aja tuotantoerä normaalisti → varmista, että kaikki tehtävät suoritetaan identtisesti kuin aiemmin
- Tarkista OPC UA:lla `IdleStartTime` -arvo: se päivittyy Phase 4→0 siirtymässä

### Vaihe 3: Gateway-integraatio (OPC UA + konfiguraatio)

Tämä vaihe kytkee Gatewayn kirjoittamaan `MoveAway`-arvon PLC:lle.
Vaiheen jälkeen move away on täysin toiminnallinen.

| Askel | Tiedosto | Toimenpide |
|-------|----------|------------|
| 3.1 | `services/gateway/opcua_nodes.js` | Lisää `stationWrite()`-funktioon `move_away` node (tyyppi INT, polku `Stations[stn].MoveAway`) |
| 3.2 | `services/gateway/opcua_adapter.js` | Kirjoita `move_away` → `MoveAway` konfiguraatiokirjoituksessa |
| 3.3 | `data/plant_templates/*/stations.json` | Lisää `"move_away": 0` kaikkiin asemiin templateissa |

**Validointi V3:**
- `docker compose build gateway && docker compose up -d gateway`
- Tarkista Gateway-login, ettei virheilmoituksia
- Aseta yhdelle asemalle testikonfiguraatioon `"move_away": 10` (lyhyt aika testaukseen)
- Käynnistä simulaatio, aja nostin kyseiselle asemalle tehtävän kautta
- Odota 10 sekuntia → varmista, että nostin siirtyy vähintään 2 asemaa pois
  - Tarkista: Phase siirtyy 0 → 1 (Status pysyy 3)
  - Tarkista: Nostin pysähtyy kohde-asemalle ja palaa Phase=0
  - Tarkista: `IdleStartTime` päivittyy paluu-adlessa kohdeasemalle

### Vaihe 4: Toiminnallinen validointi (kaikki skenaariot)

Tämä vaihe ei sisällä koodimuutoksia. Se on puhdas testausvaihe.

---

## Validointimenettelyt

### V-TEST-01: Perussiirto

**Edellytykset:** Yksi nostin (T1), asema 105 on lastausasema (`move_away: 5`),
asemat 103 ja 107 ovat normaaleja (`move_away: 0`).

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Aja erä, jonka viimeinen SinkStation = 105 | Nostin laskee erän asemalle 105 |
| 2 | Tehtävä päättyy, nostin siirtyy Phase=0, Status=3 | `IdleStartTime = g_time_s` |
| 3 | Odota 5 sekuntia | Nostin pysyy paikallaan |
| 4 | Scheduler-kierros: `STC_MoveAway` laukeaa | Phase := 1, Status = 3, LiftStationTarget = kohdeasema (≥2 asemaväliä) |
| 5 | SIM ajaa nostimen kohteeseen | Nostin liikkuu X-akselilla kohteeseen |
| 6 | Nostin saapuu kohteeseen | Phase := 0, IdleStartTime := g_time_s (uusi leimaus) |

**Hyväksymiskriteerit:**
- Nostin ei suorita Z-akselin nostoa/laskua (Phase 2 ei tapahdu)
- Kohdeaseman `MoveAway = 0`
- TWA-rajat eivät ylity missään vaiheessa

### V-TEST-02: Keskeytys oikealla tehtävällä

**Edellytykset:** Nostin T1 on poissiirtovaiheessa (Status=3, Phase=1).

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Nostin on kesken poissiirron (Phase=1, Status=3) | X-siirto kohti kohdeasemaa |
| 2 | Uusi erä saapuu: `STC_DispatchTask` valitsee T1 | T1 kelpuutetaan vapaaksi nostimeksi (Phase=1 AND Status=3) |
| 3 | Dispatch antaa oikean tehtävän | Status := 4, LiftStationTarget := uusi kohde |
| 4 | SIM vaihtaa ajokohdetta lennosta | Nostin ohjautuu suoraan oikeaan nostoasemaan |
| 5 | Nostin saapuu nostoasemalle | Phase := 2 (aloittaa noston, koska Status=4) |

**Hyväksymiskriteerit:**
- Nostin ei pysähdy välissä
- Z-nosto tapahtuu normaalisti oikealla tehtävällä
- Ei virheellisiä tilasiirtymiä (esim. Phase=2 ja Status=3 yhdistelmää ei ilmene)

### V-TEST-03: 60 sekunnin sääntö

**Edellytykset:** Nostin T1 idle asemalla 105 (`move_away: 5`).
Seuraava tehtävä Queue[1] alkaa asemalta 105 ja `PlannedStartTime - nyt < 60s`.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Idle-aika ylittää 5 sekuntia | `STC_MoveAway` tarkistaa seuraavan tehtävän |
| 2 | Seuraava tehtävä alkaa samalta asemalta < 60 s | `CONTINUE` — poissiirtoa ei tehdä |
| 3 | Nostin odottaa paikallaan | Phase = 0, Status = 3 |
| 4 | Tehtävä dispatoidaan normaalisti | Status := 4, Phase := 1 (oikea tehtävä) |

**Hyväksymiskriteerit:**
- Nostin EI aloita turhaa poissiirtoa
- Oikea tehtävä ei viivästy poissiirron takia

### V-TEST-04: TWA-prioriteetti (poissiirto vs. paikallaan oleva idle)

**Edellytykset:** Kaksi nostinta: T1 ja T2 vierekkäin. T1 on poissiirtovaiheessa
(Status=3, Phase=1), T2 on paikallaan (Status=3, Phase=0). T1 ajaa kohti T2:ta.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | T1 lähestyy T2:ta | TWA laskee prioriteetit: T1=2, T2=1 |
| 2 | Priority-vertailu pass 2:ssa | T1 voittaa → T2:n aluerajat kaventuvat |
| 3 | T2:n Idle-Clamp siirtää T2:ta pois T1:n tieltä | T2 liikkuu väistäen |
| 4 | T1 pääsee kohteeseen | T1: Phase := 0 |

**Hyväksymiskriteerit:**
- T1 (poissiirto) rajoittaa T2:ta (paikallaan idle), ei päinvastoin
- Turvavälit pysyvät voimassa koko ajan
- Ei lukkiutumisia (deadlock)

### V-TEST-05: TWA-prioriteetti (oikea tehtävä vs. poissiirto)

**Edellytykset:** T1 aktiivisessa tehtävässä (Status=4, Phase=1),
T2 poissiirtovaiheessa (Status=3, Phase=1). Ajoreitit risteävät.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | T1 ja T2 lähestyvät toisiaan | TWA: T1 priority ≥ 100000, T2 priority = 2 |
| 2 | Priority-vertailu | T1 voittaa → T2:n rajat kaventuvat |
| 3 | T2 pysähtyy / väistää dynaamiseen rajaan | T2 odottaa rajalla |
| 4 | T1 suorittaa tehtävänsä loppuun | T2:n rajat avautuvat, T2 jatkaa |

**Hyväksymiskriteerit:**
- Oikea tehtävä EI koskaan viivästy poissiirron takia
- Poissiirto odottaa rauhallisesti TWA-rajalla
- Ei törmäyksiä

### V-TEST-06: Reuna-aseman umpikuja

**Edellytykset:** Nostin T1 idle asemalla 100 (`move_away: 5`).
Asema 100 on vasemmanpuoleisin asema (DrivePosMin).

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | `STC_MoveAway` valitsee suunnaksi vasemman (-1) | `find_station_offset` palauttaa 0 |
| 2 | Suunnanvaihto: dir := +1 | `find_station_offset` etsii oikealta |
| 3 | Löytyy asema (esim. 102) jolla MoveAway=0 | Phase := 1, LiftStationTarget := 102 |

**Hyväksymiskriteerit:**
- Nostin ei jää ikuisesti reunalle
- Suunnanvaihto toimii automaattisesti
- Jos kumpikaan suunta ei tuota tulosta, poissiirtoa ei aseteta (pahimmillaan nostin jää paikoilleen, mutta ei kaadu)

### V-TEST-07: Ketjutetut MoveAway-asemat

**Edellytykset:** Asemat 104, 105, 106 kaikilla `move_away > 0`.
Asema 107 on `move_away = 0`. Nostin T1 idle asemalla 105.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | `STC_MoveAway`: dest_stn = 107 (ohittaa ketjun) | `find_station_offset` käy 105→107, tarkistaa MoveAway jokaiselle |
| 2 | 107:llä MoveAway = 0 → hyväksytään | LiftStationTarget := 107 |

**Hyväksymiskriteerit:**
- Nostin ei jää millekään MoveAway-asemalle
- WHILE-silmukka etenee oikein eikä lukkiudu

### V-TEST-08: Init ja Clear

**Edellytykset:** Järjestelmä käynnistetty tai clearatty.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Gateway lähettää `cmd=2` (init) | `PLC_PRG`: `IdleStartTime := g_time_s` kaikille aktiivisille nostimille |
| 2 | Gateway lähettää `cmd=3` (clear) | `SIM_FB_ClearConfig`: Phase:=0, Status:=3, IdleStartTime:=g_time_s |
| 3 | Move away ei laukea heti (idle-aika = 0) | Nostimet pysyvät paikallaan kunnes `move_away` aika kuluu |

**Hyväksymiskriteerit:**
- Tuore käynnistys ei aiheuta välitöntä spurious-poissiirtoa
- `IdleStartTime` on aina alustettu ennen kuin `STC_MoveAway` lukee sitä

### V-TEST-09: Regressio — normaali tuotanto ilman MoveAway-asemia

**Edellytykset:** Kaikkien asemien `move_away = 0`.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Aja normaali tuotantoerä | Tehtävät suoritetaan identtisesti kuin ennen move away -toteutusta |
| 2 | Nostin jää Phase=0 viimeiselle asemalle | Ei poissiirtoa (MoveAway=0) |
| 3 | Tarkista liikeajat `export_movement_times.js` | Identtiset aiemmin tallennettuihin referenssiarvoihin |

**Hyväksymiskriteerit:**
- Nolla-regressio: järjestelmä käyttäytyy tismalleen kuten ennen koodimuutoksia
- Scheduler-kierrosaika ei kasva merkittävästi (vaihe 2202 on O(n) missä n = nostimet)

### V-TEST-10: Useamman nostimen samanaikainen poissiirto

**Edellytykset:** T1 ja T2 molemmat idlenä eri MoveAway-asemilla.

| Askel | Toimenpide | Odotettu tulos |
|-------|-----------|----------------|
| 1 | Molemmat idle-ajat ylittyvät (eri aikaan tai samaan aikaan) | Kumpikin saa oman poissiirtokohteen |
| 2 | Jos kohteet risteävät | TWA:n prioriteetti 2 vs 2 → turvavälilogiikka ratkaisee |
| 3 | Kumpikin nostin saapuu kohteeseensa | Phase := 0 kummallakin |

**Hyväksymiskriteerit:**
- Ei törmäyksiä
- Ei lukkiutumisia (molemmat eivät odota toisiaan)
- TWA:n ID-pohjainen tasatilanne toimii oikein

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
