---
name: platform-ops
description: Day-2 operations for the kovostack platform VM — diagnosing a service that will not start, upgrading images, Postgres/registry/Infisical troubleshooting, backup and restore. Use when something in the stack is broken, needs updating, or needs a backup.
---

# Platform operations

## First moves for anything broken

```bash
make check                     # does the merged config even render?
make ps                        # what is up / restarting / unhealthy?
make logs S=<service>
docker compose config | less   # what Compose actually resolved
```

`make check` failing with `set X in .env` means a required variable is missing
— that is a `.env` problem, not a compose problem.

## Known failure modes

**Service starts but has no data / empty config** — `COMPOSE_FILE` in `.env` is
missing that app's override file. The base compose has no volumes by design.

**Volumes point outside the repo** — a relative path was written as `./data`
inside `<app>/compose.override.yml`. Paths resolve against the repo root; it
must be `./<app>/data`.

**Infisical restart-loops** — check, in order: Redis healthy and password
matching `REDIS_URL`; the `infisical` role/database existing in Postgres;
`INFISICAL_ENCRYPTION_KEY` unchanged since first boot (a changed key cannot
decrypt existing rows). Migrations run automatically at start, so the logs name
the failing step.

**A new database from `postgres/init/` never appeared** — those scripts run
only when `postgres/data` is empty. Create it manually with the SQL in the
README.

**zot UI 404s** — the image was switched to `zot-minimal-*`, or
`extensions.ui.enable` / `extensions.search.enable` was dropped from
`zot/config/config.json`. Restart zot after any config edit; it does not
hot-reload.

**`docker compose exec zot ...` fails** — the image is distroless. Inspect it
from outside with `docker compose logs zot` and the HTTP API.

**Registry push denied** — only the user named `admin` has write access
(`adminPolicy`); everyone else is read-only and anonymous is denied. Add users
with `make zot-user U=<user> P=<pw>`.

## Upgrading

Pin the new tag in `.env` (`ZOT_VERSION=`, `INFISICAL_VERSION=`, …) rather than
editing the compose, then:

```bash
make backup     # always before an Infisical or Postgres bump
make pull
make ps && make logs S=<service>
```

Postgres **major** upgrades are not in-place — dump with `make backup`, move
`postgres/data` aside, start the new version, restore. Never bump
`POSTGRES_VERSION` across a major and expect the existing data directory to
mount.

## Backup and restore

What must be backed up: `postgres/data` (or dumps), `zot/data`, `redis/data`,
plus `.env` and `zot/config/htpasswd` — the last two are git-ignored and exist
only on the VM. `INFISICAL_ENCRYPTION_KEY` belongs in an off-VM location; a
Postgres dump without it is worthless.

```bash
make backup                                    # pg_dumpall → backups/
make down && tar czf platform-data.tgz */data  # cold copy of all state
```

Restore:

```bash
make down
gunzip -c backups/postgres-<ts>.sql.gz | docker compose exec -T postgres \
  psql -U postgres -d postgres
```