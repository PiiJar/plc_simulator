# GVL_Parameters — Simulaattori vs. Tuotanto

| Simulaattori (GVLs/) | Tuotanto (docs/Parameters/) | Tyyppi | Tila |
|---|---|---|---|
| `CountStations` | `CountStations` | `INT` | ✅ |
| `Stations` | `Stations` | `ARRAY OF UDT_StationType` | ✅ |
| `Transporters` | `Transporters` | `ARRAY OF UDT_TransporterType` | ✅ |
| `TreatmentPrograms` | `TreatmentPrograms` | `ARRAY OF UDT_TreatmentProgramType` | ✅ |
| `g_station_occupancy` | — | `ARRAY OF UDT_JC_UnitAtStationType` | ⬜ Simulaattorispesifi |
| `g_transporter` | — | `ARRAY OF UDT_TransporterStatusType` | ⬜ Runtime-status, ei parametri |
| `g_unit` | — | `ARRAY OF UDT_JC_UnitType` | ⬜ Runtime-tila |
| `g_batch` | — | `ARRAY OF UDT_BatchType` | ⬜ Runtime-tila |
| `g_avoid_status` | — | `ARRAY OF INT` | ⬜ Simulaattorispesifi |
