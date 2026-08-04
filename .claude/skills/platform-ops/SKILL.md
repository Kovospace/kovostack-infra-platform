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

**zot exits immediately at first start** — `zot/config/htpasswd` does not
exist. Auth is configured, so a missing file is fatal:
`make zot-user U=admin P=<pw>`. The symptom through the proxy is a 502/503.

**acme exits with "can't get docker-gen container id"** — misleading message;
it almost always means **the proxy container is not running**, not that
anything is wrong with docker-gen. acme-companion's entrypoint returns
`NGINX_PROXY_CONTAINER` without checking the container exists, so the failure
surfaces one check later. This repo therefore identifies the proxy with the
`com.github.nginx-proxy.nginx` label instead, and gates acme on
`condition: service_healthy` — if you see this error, look at why the proxy is
down (usually port 80/443 already bound) rather than at acme.

**Certificate not issued** — check in order: does the hostname resolve to this
VM (`dig +short <host>`); is inbound 80 reachable (HTTP-01 needs it, check
`ufw status`); does the container have both `VIRTUAL_HOST` and
`LETSENCRYPT_HOST`; `make logs S=acme`. If Let's Encrypt has rate-limited you
(5 failures/hour, 50 certs/week per domain), switch `ACME_CA_URI` to staging
until the plumbing works, then switch back and
`docker compose up -d --force-recreate acme`.

**413 Request Entity Too Large on docker push** — the per-vhost file is not
being applied. It is mounted at `/etc/nginx/vhost.d/${REGISTRY_HOST}`, so a
changed `REGISTRY_HOST` silently orphans it. Verify with
`docker compose exec proxy cat /etc/nginx/vhost.d/<host>`.

**Ports 80/443 already in use** — something else took the edge, almost always
a k3s install that kept its default Traefik + ServiceLB. Reinstall k3s with
`--disable=traefik --disable=servicelb` and give the cluster ingress a
NodePort. Fall back to `localhost:5000` over an SSH tunnel meanwhile.

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