# Source from old repository

This repository was migrated from the legacy repository `OpenPLC_Simulator`.

## Migrated areas

- `codesys/` -> `services/codesys/`
- `codesys/gateway/` -> `services/gateway/`
- `PLC Simulator/visualization/` -> `services/ui/`
- `customers/` -> `data/customers/`
- `plant_templates/` -> `data/plant_templates/`
- `runtime/` -> `data/runtime/`
- `not_used/openplc/db/init.sql` -> `services/db/init.sql`

## Explicitly excluded from the new repository

- legacy OpenPLC runtime tree
- old OpenPLC build and deploy scripts
- `not_used/openplc/` except for the DB init schema source
- the old repository root structure as a product structure

## Migration principle

The old repository is source material and historical reference.
The new repository is the clean active product repository.
