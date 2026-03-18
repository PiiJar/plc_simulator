# Phase 9 validation snapshot — 2026-03-18

## Goal

Validate the migrated repository stack technically from the new repository.

## Command used

- `docker compose -f infra/docker-compose.yml up -d --build`

## Result summary

### Passed

- `codesys` container starts from the new compose
- `gateway` container starts from the new compose
- `ui` container starts from the new compose
- `db` container starts from the new compose
- UI responds on `http://localhost:5173`
- gateway API responds on `http://localhost:3001`
- gateway sees mounted data under `/data/customers`, `/data/plant_templates`, `/data/runtime`
- PostgreSQL init schema is applied successfully
- CODESYS runtime listener on `11740/tcp` responds

### Blocked

- gateway does not yet establish an OPC UA session to the runtime
- observed gateway status response includes:
  - `"runtime_status":"running"`
  - `"connected":false`
  - `"plc_alive":false`

## Observed blocker details

Gateway logs show repeated OPC UA session failures:
- `BadUserAccessDenied (0x801f0000)`

This indicates that the remaining issue is not basic container startup or port exposure.
It is an OPC UA access-policy or authentication/authorization issue between the migrated gateway and the CODESYS runtime.

## Verified checks

### UI HTTP check

- `curl http://localhost:5173` returned HTML

### Gateway HTTP checks

- `curl http://localhost:3001/api/plc/status` returned JSON
- `curl http://localhost:3001/api/customers` returned customer data
- `curl http://localhost:3001/api/plant-setups` returned template data

### Database check

The database contains the expected objects:
- tables: `events`, `sim_log`
- views: `task_dispatched`, `lift_events`, `task_complete`

### Runtime check

- probing `11740/tcp` from inside `codesys_plc` succeeded

## Conclusion

Phase 9 has been executed from the new repository and the migrated stack is operational at the container, HTTP, data-mount, and database levels.

The only remaining technical blocker for full green status is OPC UA session authorization to the CODESYS runtime.
