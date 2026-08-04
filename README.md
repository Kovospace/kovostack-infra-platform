# kovostack-infra-platform

GitOps repository for the **platform layer** of a single VM: the Docker Compose
files and configuration for the shared services that the Kubernetes cluster
running on the same machine will later consume.

This repo deliberately stops at the platform boundary. Kubernetes manifests,
Helm charts and Argo CD applications live in a separate GitOps repository — the
services here are what that repository *points at* (registry, secrets, database).

```
                       ┌─────────────────────────────────────────┐
                       │  VM  (docker compose, platform-network)  │
  cluster / CI ──────► │                                          │
   pulls images        │   zot ──── registry: images + charts     │
   reads secrets       │   infisical ── secrets, UI + API         │
   stores state        │   postgres ─── one database per app      │
                       │   redis ────── queues for infisical      │
                       └─────────────────────────────────────────┘
```

## The stack

| App | Image | Port (localhost) | Purpose |
| --- | --- | --- | --- |
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

## How the composes are wired

There is one base file plus one override per app:

```
docker-compose.yml                  base: images, env, network, healthchecks, depends_on
postgres/compose.override.yml       data + init bind mounts, published port, shm_size
redis/compose.override.yml          data bind mount
zot/compose.override.yml            config + data bind mounts, published port
infisical/compose.override.yml      published port, optional SMTP
```

The base file describes *what the platform is* and is host-independent. Each
override adds *how it runs on this machine* — bind mounts, published ports, log
rotation. Docker Compose deep-merges them, so an app can be reconfigured (or a
second VM given different paths) without touching the shared topology.

They are chained through `COMPOSE_FILE` in `.env`:

```dotenv
COMPOSE_FILE=docker-compose.yml:postgres/compose.override.yml:redis/compose.override.yml:zot/compose.override.yml:infisical/compose.override.yml
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

```bash
git clone <this repo> /opt/platform && cd /opt/platform

cp .env.example .env
chmod 600 .env
make secrets >> /tmp/secrets   # generate values, paste them into .env
$EDITOR .env

# registry admin user (pushes are restricted to the user named "admin")
make zot-user U=admin P='<password>'

make up
make ps
```

Then:

- **Infisical** — <http://localhost:8080>, create the first admin account
  immediately; signup is open until one exists.
- **zot UI** — <http://localhost:5000>, log in with the htpasswd credentials.

Everything binds to `127.0.0.1`. Reach it over an SSH tunnel, or put a
TLS-terminating reverse proxy in front before exposing anything — Docker and
Helm both refuse plain-HTTP remote registries.

## Values to set by hand

Set these in `.env` on the server (or export them in the shell that runs
`docker compose`). Compose fails fast with a clear message if a required one is
missing. Nothing in this table may ever be committed.

| Variable | Required | How to generate | Notes |
| --- | --- | --- | --- |
| `COMPOSE_FILE` | ✅ | copy from `.env.example` | Chains the override files. Without it only the base compose loads and nothing gets its volumes. |
| `COMPOSE_PROJECT_NAME` | — | `platform` | Keeps container/network names stable. |
| `POSTGRES_USER` | — | `postgres` | Superuser name. Admin and backups only. |
| `POSTGRES_PASSWORD` | ✅ | `openssl rand -hex 24` | Superuser password. Read on every start. |
| `POSTGRES_PORT` | — | `5432` | Published on loopback only. |
| `REDIS_PASSWORD` | ✅ | `openssl rand -hex 24` | Also interpolated into `REDIS_URL` — keep it alphanumeric. |
| `INFISICAL_DB_PASSWORD` | ✅ | `openssl rand -hex 24` | Password for the `infisical` role. **Only applied on the first Postgres boot**; changing it later needs an `ALTER ROLE` too. |
| `INFISICAL_ENCRYPTION_KEY` | ✅ | `openssl rand -hex 16` | Root key for stored secrets. **Lose it and every secret is unrecoverable.** Back it up off this VM. Exactly 32 hex chars. |
| `INFISICAL_AUTH_SECRET` | ✅ | `openssl rand -base64 32` | Signs sessions/JWTs. Rotating it logs everyone out. |
| `INFISICAL_SITE_URL` | ✅ | `https://secrets.example.com` | Public URL used to build invite and password-reset links. Wrong value ⇒ broken emails. |
| `INFISICAL_PORT` | — | `8080` | Published on loopback only. |
| `ZOT_PORT` | — | `5000` | Published on loopback only. |
| `SMTP_HOST` `SMTP_PORT` `SMTP_USERNAME` `SMTP_PASSWORD` `SMTP_FROM_ADDRESS` `SMTP_FROM_NAME` | — | provider-specific | Optional. Without them Infisical cannot send invites, password resets or alerts. |
| `POSTGRES_VERSION` `REDIS_VERSION` `ZOT_VERSION` `INFISICAL_VERSION` | — | image tags | Pin these in production; the compose defaults float. |

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
docker login localhost:5000

docker push localhost:5000/myapp:1.0.0

helm package ./chart
helm push mychart-1.0.0.tgz oci://localhost:5000/charts
helm pull oci://localhost:5000/charts/mychart --version 1.0.0
```

Both land in the same OCI storage; the UI lists images and charts side by side.
From the Kubernetes side, the cluster pulls from this registry with an
`imagePullSecret`, and Argo CD reads charts from `oci://.../charts` — configured
in the *other* GitOps repo, not here.

## Conventions

- Secrets never enter git. `.env`, `zot/config/htpasswd` and all `*/data`
  directories are ignored.
- Every app gets its own Postgres role and database, named after the app.
- Services talk to each other by service name over `platform-network`
  (`postgres:5432`, `redis:6379`, `zot:5000`); host ports are for humans.
- Passwords stay alphanumeric — they end up inside connection URLs.
- Image tags are variables, overridable from `.env`.