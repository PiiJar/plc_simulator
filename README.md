# plc-simulator

Clean repository for the active CODESYS-based PLC simulator product.

## Repository structure

```text
plc-simulator/
├── services/
│   ├── codesys/
│   ├── gateway/
│   ├── ui/
│   └── db/
├── data/
│   ├── customers/
│   ├── plant_templates/
│   └── runtime/
├── infra/
│   └── scripts/
└── docs/
    ├── setup/
    ├── migration/
    └── troubleshooting/
```

## Scope

This repository is intended to contain only the active product parts:
- CODESYS service
- gateway service
- UI service
- database assets if required
- customer, template, and runtime data
- setup and troubleshooting documentation

Legacy OpenPLC assets are intentionally excluded.

## Status

Initial repository scaffold created on 2026-03-17.

Current migration status:
- CODESYS core sources migrated to `services/codesys/`
- gateway sources migrated to `services/gateway/`
- gateway currently expects PostgreSQL event storage
- UI sources migrated to `services/ui/`
- active data migrated to `data/customers/`, `data/plant_templates/`, and `data/runtime/`
- PostgreSQL init schema migrated to `services/db/init.sql`
- clean stack compose added at `infra/docker-compose.yml`
- baseline setup and migration docs added under `docs/`
- phase 9 stack validation executed from the new repo
- remaining blocker: gateway OPC UA session is denied by the runtime (`BadUserAccessDenied`)

## Quick start

Build and start the stack:

- `docker compose -f infra/docker-compose.yml up -d --build`

Build the UI locally:

- `cd services/ui`
- `npm ci`
- `npm run build`

Build PLCopenXML locally:

- `cd services/codesys`
- `python3 build_codesys_xml.py`

## Documentation

- setup: `docs/setup/SETUP.md`
- troubleshooting: `docs/troubleshooting/CODESYS_CONNECTIVITY.md`
- phase 9 validation snapshot: `docs/troubleshooting/PHASE9_VALIDATION_2026-03-18.md`
- migration source mapping: `docs/migration/SOURCE_FROM_OLD_REPO.md`
