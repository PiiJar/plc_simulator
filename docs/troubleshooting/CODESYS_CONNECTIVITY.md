# CODESYS connectivity

## Verified facts

Current verified Linux runtime facts:
- container name: `codesys_plc`
- image: `joyja/codesys-control:version-4.12.00`
- network mode: `host`
- runtime port: `11740/tcp`

## Common checks

### 1. Check containers

- `docker compose -f infra/docker-compose.yml ps`

### 2. Check gateway logs

- `docker compose -f infra/docker-compose.yml logs gateway`

### 3. Check database logs

- `docker compose -f infra/docker-compose.yml logs db`

### 4. Check UI logs

- `docker compose -f infra/docker-compose.yml logs ui`

## Windows IDE note

The supported runtime baseline documented during migration is `4.12.00`.
If Windows tooling shows `4.19`, treat that as a version mismatch until explicitly validated.

## Known migration-era constraint

The runtime listener verified during migration is port `11740/tcp`.
If the Windows IDE cannot connect, verify:
- host/IP reachability
- firewall rules
- runtime version compatibility
- VM/LAN topology if Windows runs inside a VM
