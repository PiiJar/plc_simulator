# GVL_Parameters — Simulaattori vs. Tuotanto

| Simulaattori (GVLs/) | Tuotanto (docs/Parameters/) | Tyyppi | Huomio |
|---|---|---|---|
| `CountStations` | `CountStations` | `INT` | Sama nimi |
| `Stations` | `Stations` | `ARRAY OF UDT_StationType` | Sama nimi |
| `g_station_loc` | — | `ARRAY OF UDT_UnitLocation` | Simulaattorispesifi |
| `g_cfg` | `Transporters` | `ARRAY OF UDT_TransporterType` | Indeksointi eroaa: sim 1-alkuinen, tuotanto 0-alkuinen |
| `g_transporter` | — | `ARRAY OF UDT_TransporterStatusType` | Runtime-status, ei parametri |
| `g_unit` | — | `ARRAY OF UDT_UnitType` | Runtime-tila |
| `g_batch` | — | `ARRAY OF UDT_BatchType` | Runtime-tila |
| `g_program` | `TreatmentPrograms` | `ARRAY OF UDT_TreatmentProgramType` | Eri semantiikka: sim per unit, tuotanto ohjelmakirjasto |
| `g_avoid_status` | — | `ARRAY OF INT` | Simulaattorispesifi |
