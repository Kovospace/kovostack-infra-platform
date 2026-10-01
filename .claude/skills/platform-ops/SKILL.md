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

**A platform hostname suddenly behaves like a cluster app** (wrong certificate,
a 404 from Traefik, or a TLS handshake failure) — the edge routes by SNI and
its map lists only the platform hostnames; everything else goes to Kubernetes.
A name missing from `edge/sni.conf.stream-template`, or a typo in it, is
routed into the cluster. `make check-edge` renders the map with the real values
and `make logs S=edge` shows one line per connection: `client -> SNI
[upstream]`.

**Every cluster hostname 502s or hangs, platform hostnames fine** — the
containers cannot reach the ingress NodePorts. `make cluster-check`. Under
rootless Docker `CLUSTER_INGRESS_IP` must be the VM's routable address; the
host's loopback is not reachable from a container. After changing it, the proxy
needs `--force-recreate` (the address is an `/etc/hosts` entry, resolved once
at startup), not just a restart.

**The edge starts but refuses every connection** — the stream config was not
loaded. The template must be named `*.conf.stream-template`; the entrypoint
strips only `.stream-template`, and the generated include matches `*.conf`.
`nginx -t` passes either way, `make check-edge` fails loudly.

**nginx-proxy will not start after editing `proxy/conf.d/`** — with
`ENABLE_PROXY_PROTOCOL` the `:80`/`:443` listeners all expect a PROXY header,
and every server block sharing a listen socket must declare `proxy_protocol`
identically. A hand-written block missing it fails config parsing.

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

**acme exits with "can't get my container ID" / "can't get nginx-proxy
container ID" / "can't get docker-gen container id"** — all three are the same
fault: **acme cannot query the Docker API**. Run `make doctor` first; it
compares the socket the stack mounts against the one the CLI talks to and
prints the fix.

The usual cause is rootless Docker with `DOCKER_HOST_PATH` unset, so the stack
mounts `/var/run/docker.sock` (which exists, owned `root:docker`) while the
containers run under the rootless daemon — every call is denied. Set
`DOCKER_HOST_PATH=/run/user/<uid>/docker.sock`.

Do not chase the specific wording: which message appears depends only on which
lookup runs first. `NGINX_PROXY_CONTAINER` is deliberately not set in this repo
because it is trusted without an existence check and converts the clear error
into the docker-gen one.

Also check that a failed start has not left a **directory** where the socket
should be (`ls -ld <path>`) — Docker creates bind-mount sources that do not
exist, and it then shadows the real socket permanently.

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

**Registry access denied for a user that definitely exists** — an htpasswd
entry grants nothing by itself. `defaultPolicy` is empty in
`zot/config/config.json`, so a user is denied until a policy names it, and the
repository patterns do not merge: a policy on `**` does not apply to a
repository that also matches `apps/**`. Check which pattern the repository hits
and whether the user is listed *there*. `make restart S=zot` after editing.

**Registry push fails with 502 after ~60s, zot logs `i/o timeout` with
`latency: 1m0s`** — zot ≥ v2.1.17 applies `http.readTimeout`/`writeTimeout` to
the *whole* request (default 60s), so any layer that takes longer to upload is
cut off mid-stream; nginx-proxy reports zot's 500 as 502. `zot/config/config.json`
sets both to `15m` to match the proxy's 900s. Keep `ZOT_VERSION` pinned and
re-check this on upgrades until upstream #4149 (per-chunk deadlines) ships.

**Registry push denied, pull works** — the robot has `create` but not `update`,
which is deliberate: it can push a new tag but not move an existing one. A
retried CI job that already pushed will hit this.

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