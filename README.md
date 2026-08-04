# kovostack-infra-platform

GitOps repository for the **platform layer** of a single VM: the Docker Compose
files and configuration for the shared services that the Kubernetes cluster
running on the same machine will later consume.

This repo deliberately stops at the platform boundary. Kubernetes manifests,
Helm charts and Argo CD applications live in a separate GitOps repository — the
services here are what that repository *points at* (registry, secrets, database).

```
                    ┌──────────────────────────────────────────────┐
                    │   VM  (docker compose, platform-network)     │
   internet ──443──►│  nginx-proxy + acme-companion  (TLS edge)    │
                    │        │                                     │
   cluster / CI ───►│        ├── zot ──── registry: images+charts  │
    pulls images    │        └── infisical ── secrets, UI + API    │
    reads secrets   │            postgres ─── one database per app │
    stores state    │            redis ────── queues for infisical │
                    └──────────────────────────────────────────────┘
```

## The stack

| App | Image | Port (localhost) | Purpose |
| --- | --- | --- | --- |
| **nginx-proxy** | `nginxproxy/nginx-proxy:alpine` | 80, 443 | TLS edge for the platform. Discovers backends by their `VIRTUAL_HOST` env var over the Docker socket — no central config to edit. |
| **acme-companion** | `nginxproxy/acme-companion` | — | Issues and renews Let's Encrypt certificates for every container carrying `LETSENCRYPT_HOST`. |
| **PostgreSQL 17** | `postgres:17-alpine` | 5432 | Shared cluster, **one role + one database per app**. Roles own only their own database, so apps cannot read each other's data. |
| **Redis 7** | `redis:7-alpine` | — | Job queues and caching for Infisical. Not published; internal only. |
| **zot** | `ghcr.io/project-zot/zot-linux-amd64` | 5000 | OCI-native registry for **container images and Helm charts**. Vendor-neutral, CNCF, no Docker Hub rate limits. |
| **Infisical** | `infisical/infisical` | 8080 | Secrets manager — the light alternative to HashiCorp Vault. Web UI, CLI, Kubernetes operator, API. |

### Does zot have a UI?

Yes. zot ships a built-in web UI (**ZUI**) — repository browsing, tags, image
metadata, CVE reports from the `search` extension. It is enabled in
`zot/config/config.json` via `extensions.ui.enable` and served from the registry
port itself: <http://localhost:5000>.

Two caveats worth knowing:

- The UI only exists in the **full** image (`zot-linux-amd64`). The
  `zot-minimal-*` images are built without extensions and have no UI.
- The UI needs the `search` extension enabled to show anything useful; both are
  already on in the committed config.

CVE scanning downloads and refreshes the Trivy database into `zot/data/_trivy`
(a few hundred MB, every `extensions.search.cve.updateInterval`). On a
bandwidth- or disk-constrained VM, lengthen that interval or drop the `cve`
block from `zot/config/config.json` — the rest of the UI keeps working.

### Why Infisical over Vault

Vault is a few hundred MB of RSS, needs unsealing on every restart, and its
policy/auth model is a project of its own. Infisical is a single Node service
plus Postgres and Redis, has a usable UI out of the box, and covers what a
single-VM platform actually needs: project-scoped secrets, machine identities,
a Kubernetes operator, and secret injection into CI. If you later need dynamic
database credentials or PKI issuance at scale, that is the point to revisit
Vault — not before.

## TLS, and why the proxy lives here rather than in Kubernetes

The platform terminates its own TLS and has **no ordering dependency on the
cluster**. That is deliberate: if the cluster's ingress fronted zot, then the
cluster would need images, the images would live in zot, and zot would only be
reachable through the cluster. Circular — and it fails exactly when you are
trying to recover from an outage.

Two independent certificate domains, permanently:

| Layer | Fronted by | Certificates from |
| --- | --- | --- |
| Platform — zot, Infisical | `nginx-proxy` in this repo | acme-companion, directly |
| Cluster workloads | ingress controller in the cluster | cert-manager |

`registry.example.com` never touches Kubernetes.

### Plan the port conflict before installing k3s

This proxy owns host ports 80 and 443. Only one process can. **k3s ships Traefik
as its default ingress and its ServiceLB binds those same ports**, so a default
k3s install will collide with the platform edge:

```bash
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --disable=servicelb
```

Then run the ingress controller of your choice (Traefik or ingress-nginx) as a
NodePort service on 30080/30443, and forward the cluster's wildcard hostname to
it from this proxy: nginx-proxy only auto-generates vhosts for *containers*, so
a NodePort backend needs a hand-written server block mounted into
`/etc/nginx/conf.d/` — there is a commented-out mount ready for it in
`proxy/compose.override.yml`. One front door, one place where TLS is
terminated, and the platform stays up when the cluster is down.

Note this has nothing to do with Traefik specifically — ingress-nginx would
contend for the same ports. The choice of ingress controller inside the cluster
is independent of what runs here.

If you would rather keep the two layers fully separate, Netcup gives the VM an
IPv6 /64: bind the cluster ingress to its own address and both layers get real
80/443 with no forwarding and no shared certificates.

### Certificate issuance

Validation is HTTP-01, so before the first start both `REGISTRY_HOST` and
`SECRETS_HOST` must already resolve to this VM and port 80 must be reachable
from the internet (check `ufw`/`nftables` on the VM — Netcup does not firewall
by default).

Let's Encrypt rate-limits failures hard: 5 per hour, 50 certificates per week
per registered domain. Get the plumbing right against staging first:

```dotenv
ACME_CA_URI=https://acme-staging-v02.api.letsencrypt.org/directory
```

Your browser will reject the staging certificate — that is expected; you are
only proving that issuance succeeds. Then comment the line out and:

```bash
docker compose up -d --force-recreate acme
docker compose logs -f acme
```

If acme exits with `can't get docker-gen container id`, the proxy container is
not running — the message is misleading. acme-companion accepts
`NGINX_PROXY_CONTAINER` without checking that the container exists, so the
failure surfaces one check later as a docker-gen problem. This stack therefore
identifies the proxy by the `com.github.nginx-proxy.nginx` label and gates acme
on the proxy's healthcheck, so the real cause — usually port 80 already bound —
shows up directly.

### The registry needs its own nginx tuning

`proxy/vhost.d/registry` is mounted as `/etc/nginx/vhost.d/${REGISTRY_HOST}`
(compose interpolates the mount target) and raises the limits that would
otherwise break pushes:

- `client_max_body_size 0` — nginx's default is **1 MB**, which rejects
  essentially every image layer.
- `proxy_request_buffering off` — without it nginx spools each multi-GB layer
  to its own disk before contacting zot.
- 900 s read/send timeouts for large layers over a slow uplink.

Everything else gets `proxy/vhost.d/default` (64 MB), which is plenty for the
Infisical UI and API.

## How the composes are wired

There is one base file plus one override per app:

```
docker-compose.yml                  base: images, env, network, healthchecks, depends_on
proxy/compose.override.yml          80/443, cert volumes, vhost.d mounts, docker socket
postgres/compose.override.yml       data + init bind mounts, published port, shm_size
redis/compose.override.yml          data bind mount
zot/compose.override.yml            config + data bind mounts, port, VIRTUAL_HOST
infisical/compose.override.yml      published port, VIRTUAL_HOST, optional SMTP
```

The base file describes *what the platform is* and is host-independent. Each
override adds *how it runs on this machine* — bind mounts, published ports, log
rotation. Docker Compose deep-merges them, so an app can be reconfigured (or a
second VM given different paths) without touching the shared topology.

They are chained through `COMPOSE_FILE` in `.env`:

```dotenv
COMPOSE_FILE=docker-compose.yml:proxy/compose.override.yml:postgres/compose.override.yml:redis/compose.override.yml:zot/compose.override.yml:infisical/compose.override.yml
```

With that set, ordinary commands just work:

```bash
docker compose up -d        # whole platform
docker compose config       # see the merged result
docker compose up -d zot    # one service
```

Without `.env` (or to run a subset deliberately) pass the files explicitly:

```bash
docker compose -f docker-compose.yml -f zot/compose.override.yml up -d zot
```

> **Relative paths in override files resolve against the repo root**, not
> against the file's own directory — that is why `zot/compose.override.yml`
> says `./zot/data`, not `./data`.

## Setup

Prerequisites: `REGISTRY_HOST` and `SECRETS_HOST` resolving to this VM, and
inbound 80/443 open.

```bash
git clone <this repo> /opt/platform && cd /opt/platform

cp .env.example .env
chmod 600 .env
make secrets >> /tmp/secrets   # generate values, paste them into .env
$EDITOR .env                   # also set the two hostnames and ACME_EMAIL

# Registry admin user. Do this BEFORE `make up`: zot refuses to start if
# zot/config/htpasswd does not exist.
make zot-user U=admin P='<password>'

make up
make ps
make logs S=acme               # watch the certificates being issued
```

Then:

- **Infisical** — `https://$SECRETS_HOST`, create the first admin account
  immediately; signup is open until one exists.
- **zot UI** — `https://$REGISTRY_HOST`, log in with the htpasswd credentials.

Only the proxy is exposed publicly. The services keep a `127.0.0.1` port for
administration and SSH tunnels, so they stay reachable even if the proxy or a
certificate is broken.

## Values to set by hand

Set these in `.env` on the server (or export them in the shell that runs
`docker compose`). Compose fails fast with a clear message if a required one is
missing. Nothing in this table may ever be committed.

| Variable | Required | How to generate | Notes |
| --- | --- | --- | --- |
| `COMPOSE_FILE` | ✅ | copy from `.env.example` | Chains the override files. Without it only the base compose loads and nothing gets its volumes. |
| `COMPOSE_PROJECT_NAME` | — | `platform` | Keeps container/network names stable. |
| `DOCKER_HOST_PATH` | — | `/run/user/1000/docker.sock` | Only for rootless Docker; defaults to `/var/run/docker.sock`. |
| `REGISTRY_HOST` | ✅ | `registry.example.com` | Public name for zot. Must resolve to this VM **before** first start — HTTP-01 validation. Also names the per-vhost nginx file. |
| `SECRETS_HOST` | ✅ | `secrets.example.com` | Public name for Infisical. Same DNS requirement. |
| `ACME_EMAIL` | ✅ | `you@example.com` | Let's Encrypt account address; receives expiry warnings. |
| `ACME_CA_URI` | — | staging URL | Leave unset for production. Point at the staging directory while testing to avoid burning rate limits. |
| `POSTGRES_USER` | — | `postgres` | Superuser name. Admin and backups only. |
| `POSTGRES_PASSWORD` | ✅ | `openssl rand -hex 24` | Superuser password. Read on every start. |
| `POSTGRES_PORT` | — | `5432` | Published on loopback only. |
| `REDIS_PASSWORD` | ✅ | `openssl rand -hex 24` | Also interpolated into `REDIS_URL` — keep it alphanumeric. |
| `INFISICAL_DB_PASSWORD` | ✅ | `openssl rand -hex 24` | Password for the `infisical` role. **Only applied on the first Postgres boot**; changing it later needs an `ALTER ROLE` too. |
| `INFISICAL_ENCRYPTION_KEY` | ✅ | `openssl rand -hex 16` | Root key for stored secrets. **Lose it and every secret is unrecoverable.** Back it up off this VM. Exactly 32 hex chars. |
| `INFISICAL_AUTH_SECRET` | ✅ | `openssl rand -base64 32` | Signs sessions/JWTs. Rotating it logs everyone out. |
| `INFISICAL_SITE_URL` | ✅ | `https://secrets.example.com` | Public URL used to build invite and password-reset links. Must match `SECRETS_HOST` including the scheme. |
| `INFISICAL_PORT` | — | `8080` | Published on loopback only. |
| `ZOT_PORT` | — | `5000` | Published on loopback only. |
| `SMTP_HOST` `SMTP_PORT` `SMTP_USERNAME` `SMTP_PASSWORD` `SMTP_FROM_ADDRESS` `SMTP_FROM_NAME` | — | provider-specific | Optional. Without them Infisical cannot send invites, password resets or alerts. |
| `POSTGRES_VERSION` `REDIS_VERSION` `ZOT_VERSION` `INFISICAL_VERSION` `NGINX_PROXY_VERSION` `ACME_COMPANION_VERSION` | — | image tags | Pin these in production; the compose defaults float. |

Registry credentials are **not** environment variables — zot reads
`zot/config/htpasswd`, which is git-ignored and created on the server:

```bash
make zot-user U=ci P='<password>'
```

The user literally named `admin` gets push/delete rights (`adminPolicy` in
`zot/config/config.json`); every other user is read-only, and anonymous access
is denied entirely.

## Operating it

```bash
make            # list all targets
make up         # start / apply changes
make ps
make logs S=infisical
make pull       # update images and recreate
make psql DB=infisical
make backup     # pg_dumpall → backups/
make down       # stop, keep data
```

State lives in bind mounts next to the composes (`postgres/data`, `redis/data`,
`zot/data`) — all git-ignored. Backing up the VM means backing up those three
directories plus `.env`.

### Adding a new app database

`postgres/init/01-init-databases.sh` runs **only when `postgres/data` is
empty**, i.e. on the very first start. For a cluster that is already running,
add the `create_app_db` line to the script (so a rebuilt VM gets it) *and*
create the database on the live cluster by hand:

```bash
make psql            # then:
```
```sql
CREATE ROLE myapp LOGIN PASSWORD '<password>';
CREATE DATABASE myapp OWNER myapp;
REVOKE ALL ON DATABASE myapp FROM PUBLIC;
\c myapp
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

Then add `MYAPP_DB_PASSWORD` to `.env.example`, to `.env`, and pass it through
in `docker-compose.yml`.

## Using the registry

```bash
docker login registry.example.com

docker push registry.example.com/myapp:1.0.0

helm package ./chart
helm push mychart-1.0.0.tgz oci://registry.example.com/charts
helm pull oci://registry.example.com/charts/mychart --version 1.0.0
```

Both land in the same OCI storage; the UI lists images and charts side by side.
From the Kubernetes side, the cluster pulls from this registry with an
`imagePullSecret`, and Argo CD reads charts from `oci://.../charts` — configured
in the *other* GitOps repo, not here.

### Before TLS exists, or when it breaks

Docker treats `127.0.0.0/8` as an insecure registry by default (`docker info`
lists it), so the loopback port works with no certificate and no daemon
configuration at all:

```bash
# on the VM
docker push localhost:5000/myapp:1.0.0
helm push mychart-1.0.0.tgz oci://localhost:5000/charts --plain-http

# from a laptop or CI runner — SSH tunnel, then the exact same commands
ssh -L 5000:localhost:5000 vm
```

The tunnel is the useful one: SSH encrypts the traffic and the client still
sees `localhost:5000`, so the loopback exemption applies. That is a complete
bootstrap workflow — the registry is usable from the moment it starts, which is
why the reverse proxy is a convenience here rather than a prerequisite.

What to avoid is adding a non-loopback address to `insecure-registries` in
`daemon.json`. It works, it survives into production, and later containerd on
the cluster needs the same exception.

## Conventions

- Secrets never enter git. `.env`, `zot/config/htpasswd` and all `*/data`
  directories are ignored.
- Every app gets its own Postgres role and database, named after the app.
- Services talk to each other by service name over `platform-network`
  (`postgres:5432`, `redis:6379`, `zot:5000`); host ports are for humans.
- Passwords stay alphanumeric — they end up inside connection URLs.
- Image tags are variables, overridable from `.env`.