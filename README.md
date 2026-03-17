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
