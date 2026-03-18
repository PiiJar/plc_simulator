# Setup

## Scope

This repository contains the active CODESYS-based PLC simulator product.

Services:
- `codesys`
- `gateway`
- `ui`
- `db`

Data roots:
- `data/customers`
- `data/plant_templates`
- `data/runtime`

## Verified runtime baseline

The currently verified runtime baseline is:
- image: `joyja/codesys-control:version-4.12.00`
- runtime port: `11740/tcp`

Do not assume a `4.19` runtime baseline.

## Build frontend locally

From the repository root:

- `cd services/ui`
- `npm ci`
- `npm run build`

## Build PLCopenXML locally

From the repository root:

- `cd services/codesys`
- `python3 build_codesys_xml.py`

Expected output:
- `services/codesys/build/project.xml`

## Start the stack

From the repository root:

- `docker compose -f infra/docker-compose.yml up -d --build`

Services exposed by default:
- UI: `http://localhost:5173`
- Gateway API: `http://localhost:3001`
- PostgreSQL: `localhost:5432`

## Notes

- The gateway expects PostgreSQL event storage.
- The gateway mounts data from `data/`.
- The gateway uses `/var/run/docker.sock` to control the PLC runtime container.
- The gateway OPC UA endpoint is currently configured to use `host.docker.internal:4840` inside Compose.
