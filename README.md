# kovostack-infra-platform

GitOps repository for the **platform layer** of a single VM: the Docker Compose
files and configuration for the shared services that the Kubernetes cluster
running on the same machine will later consume.

This repo deliberately stops at the platform boundary. Kubernetes manifests,
Helm charts and Argo CD applications live in a separate GitOps repository — the
services here are what that repository *points at* (registry, secrets, database).

```
                          internet
                        :80    :443
                          │      │
              ┌───────────▼──────▼────────────────────────────────┐
              │  edge — nginx stream, routes by SNI, decrypts     │
              │         nothing, owns the two privileged ports    │
              └───┬────────────────────────────────────┬──────────┘
                  │ registry./secrets.                 │ everything else
                  ▼                                    ▼
   ┌──────────────────────────────────┐   ┌──────────────────────────────┐
   │ nginx-proxy + acme-companion     │   │  Kubernetes (k3s, other repo)│
   │   zot ─────── images + charts    │   │    Traefik  NodePort 30443   │
   │   infisical ─ secrets, UI + API  │   │    cert-manager owns certs   │
   │   postgres ── one db per app     │   │    Argo CD, applications     │
   │   redis ───── queues             │   │                              │
   └──────────────────────────────────┘   └──────────────────────────────┘
        certs from Let's Encrypt               certs from Let's Encrypt
        via acme-companion                     via cert-manager
```

Port 80 is not split at the edge — plain HTTP carries no SNI to route on. All
of it goes to nginx-proxy, which passes the cluster's share on by Host header
(`proxy/conf.d/00-cluster.conf`); that is the path cert-manager's HTTP-01
challenges take.

## The stack

| App | Image | Port (localhost) | Purpose |
| --- | --- | --- | --- |
| **edge** | `nginx:alpine` | 80, 443 | L4 router. Splits `:443` by TLS SNI between the platform and the cluster without decrypting it, and forwards `:80` to nginx-proxy. The only container that publishes privileged ports. |
| **nginx-proxy** | `nginxproxy/nginx-proxy:alpine` | — | TLS edge for the platform, behind `edge`. Discovers backends by their `VIRTUAL_HOST` env var over the Docker socket — no central config to edit. |
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

### How the two layers share port 443

Only one process can own a port, so `edge` owns 80 and 443 and hands each
connection to whichever layer it belongs to. On 443 it reads the SNI name out
of the TLS ClientHello — which is sent in the clear, before the handshake — and
then forwards the bytes untouched:

| SNI | Goes to | Certificate issued by |
| --- | --- | --- |
| `$REGISTRY_HOST`, `$SECRETS_HOST` | nginx-proxy | acme-companion, in this repo |
| anything else | Traefik NodePort 30443 | cert-manager, in the cluster |

The platform hostnames are the exception list; the cluster is the default. That
means **adding an app to Kubernetes needs no change here at all**, but adding a
new *platform* vhost needs a line in `edge/sni.conf.stream-template` or its
traffic silently goes to the cluster.

Because the edge never terminates TLS, it holds no certificates and cares about
neither layer's issuer. And because it is L4, it keeps serving the platform
while the cluster is down — the ordering dependency stays broken in the
direction that matters.

The one thing the edge cannot route is plain HTTP: there is no SNI in it. All of
`:80` therefore goes to nginx-proxy, and `proxy/conf.d/00-cluster.conf` forwards
whatever is not a platform vhost to NodePort 30080. That block is the default
server for port 80 purely by load order — see the comment in the file before
renaming it.

### Installing k3s

k3s ships Traefik as its default ingress and its ServiceLB binds 80/443, which
would collide with the edge:

```bash
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --disable=servicelb
```

Then install Traefik yourself as a NodePort service. Two settings matter on the
platform side — the edge and nginx-proxy both announce the real client with the
PROXY protocol, and Traefik has to be told to trust it:

```yaml
# traefik helm values
service:
  type: NodePort
ports:
  web:                      # :30080, plain HTTP from nginx-proxy
    nodePort: 30080
    forwardedHeaders:
      trustedIPs: ["<edge/proxy source address>"]   # X-Forwarded-For
  websecure:                # :30443, TLS passthrough from the edge
    nodePort: 30443
    proxyProtocol:
      trustedIPs: ["<edge source address>"]
```

`websecure` receives a PROXY header and `web` does not — the hop into 30080 is
ordinary HTTP with `X-Forwarded-For` set, because nginx cannot emit a PROXY
header from its HTTP proxy module. Getting `proxyProtocol` wrong on `web`, or
missing on `websecure`, breaks the handshake rather than degrading quietly.

Find the address Traefik actually sees the platform as with
`kubectl -n kube-system logs deploy/traefik | grep ClientAddr`, and set
`CLUSTER_INGRESS_IP` to an address where the containers can reach the NodePorts:

```bash
make cluster-check      # probes 30080/30443 from inside the edge container
```

Under rootless Docker the container's `127.0.0.1` is not the host's, so the
loopback address never works — use the VM's own routable IP. Firewall
30080/30443 afterwards: on a routable address they are a second, unrouted front
door into the cluster.

If you would rather keep the two layers fully separate, Netcup gives the VM an
IPv6 /64: bind the cluster ingress to its own address and both layers get real
80/443 with no edge, no SNI routing and no shared ports.

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
on the proxy's healthcheck, so the real cause shows up directly. (The proxy
itself no longer binds 80/443 — the edge does, and that is where an "address
already in use" now comes from.)

### Rootless Docker

Both proxy containers work by watching the Docker socket, so under rootless
Docker two things must be set up before anything works. `make doctor` checks
both:

```bash
make doctor        # compares the mounted socket against the CLI's endpoint
```

**1. Mount the right socket.** Rootless uses `/run/user/<uid>/docker.sock`.
`/var/run/docker.sock` often still exists (owned `root:docker`), so the mount
silently succeeds and then every API call is denied — container-root maps to
your host uid, which is not in the `docker` group. The symptom is the
misleading `can't get docker-gen container id`, or `can't get my container ID`.

```dotenv
DOCKER_HOST_PATH=/run/user/1000/docker.sock
```

**2. Allow privileged ports.** Rootless cannot bind below 1024 by default, and
the edge container needs 80/443:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/99-rootless.conf
sudo sysctl --system
```

Never let the stack start with a wrong socket path: Docker creates a
**directory** at a missing bind-mount source, and that directory then shadows
the real socket forever. If a start has already failed, check with
`ls -ld <path>` and `sudo rmdir` anything that is not a socket.

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
edge/compose.override.yml           80/443, SNI template + healthcheck server mounts
proxy/compose.override.yml          cert volumes, vhost.d and conf.d mounts, docker socket
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
COMPOSE_FILE=docker-compose.yml:edge/compose.override.yml:proxy/compose.override.yml:postgres/compose.override.yml:redis/compose.override.yml:zot/compose.override.yml:infisical/compose.override.yml
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

Only the edge is exposed publicly. The services keep a `127.0.0.1` port for
administration and SSH tunnels, so they stay reachable even if the edge, the
proxy or a certificate is broken.

## Values to set by hand

Set these in `.env` on the server (or export them in the shell that runs
`docker compose`). Compose fails fast with a clear message if a required one is
missing. Nothing in this table may ever be committed.

| Variable | Required | How to generate | Notes |
| --- | --- | --- | --- |
| `COMPOSE_FILE` | ✅ | copy from `.env.example` | Chains the override files. Without it only the base compose loads and nothing gets its volumes. |
| `COMPOSE_PROJECT_NAME` | — | `platform` | Keeps container/network names stable. |
| `DOCKER_HOST_PATH` | — | `/run/user/1000/docker.sock` | Only for rootless Docker; defaults to `/var/run/docker.sock`. |
| `REGISTRY_HOST` | ✅ | `registry.example.com` | Public name for zot. Must resolve to this VM **before** first start — HTTP-01 validation. Also names the per-vhost nginx file, and is one of the SNI names the edge keeps out of the cluster. |
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
| `CLUSTER_INGRESS_IP` | — | the VM's own routable IP | Where NodePorts 30080/30443 are reachable **from inside a container**. Never `127.0.0.1` (that is the container's own loopback), and under rootless Docker the host's loopback is unreachable entirely. `make cluster-check` probes the candidates. Unset means cluster hostnames get a 502. |
| `POSTGRES_VERSION` `REDIS_VERSION` `ZOT_VERSION` `INFISICAL_VERSION` `NGINX_PROXY_VERSION` `ACME_COMPANION_VERSION` `NGINX_VERSION` | — | image tags | Pin these in production; the compose defaults float. `NGINX_VERSION` is plain upstream nginx, used only by the edge. |

Registry credentials are **not** environment variables — zot reads
`zot/config/htpasswd`, which is git-ignored and created on the server:

```bash
make zot-user U=ci P='<password>'
```

Access is per user, set in `accessControl` in `zot/config/config.json`. Anonymous
access is denied entirely, and **a user with no matching policy gets nothing** —
`defaultPolicy` is empty, so creating an htpasswd entry is only half of adding
someone.

| User | Can | Where |
| --- | --- | --- |
| `admin` | read, create, update, delete | everywhere (`adminPolicy`) |
| `ci` | read, create, update | `apps/**`, `charts/**` — the GitHub Actions robot |
| `k8s` | read | everywhere — the cluster's pull credential |

The patterns do **not** merge: a repository matching both `**` and `apps/**` is
governed by the specific block alone, so every user that needs access to it has
to be listed there. That is why `k8s` appears in all three.

Two consequences worth knowing:

- Dropping `update` from a robot gives you tag immutability — it can push a new
  tag but cannot move an existing one. Good for release tags, awkward for a
  rebuilt `:latest` or a retried CI job.
- `/v2/_catalog` is filtered per user, so a scoped robot cannot even enumerate
  the repositories it is not allowed to pull.

Adding a robot is two steps and a restart:

```bash
make zot-user U=ci P='<password>'   # htpasswd entry
$EDITOR zot/config/config.json      # list it in the policies it needs
make restart S=zot
```

## Operating it

```bash
make            # list all targets
make up         # start / apply changes
make ps
make check-edge     # render the SNI map with the real hostnames and validate it
make cluster-check  # can the containers reach the ingress NodePorts?
make logs S=edge    # one line per connection: client -> SNI [upstream]
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

> **`OWNER myapp` is load-bearing — the app's migrations depend on it.**
> Since PostgreSQL 15 the `public` schema is owned by `pg_database_owner`, a
> role that resolves to whoever owns the current database, and `PUBLIC` no
> longer has `CREATE` on it. Creating the database that way makes the app role
> the owner of `public` implicitly, which is what lets it create tables. The
> plausible-looking alternative
>
> ```sql
> CREATE DATABASE myapp;                            -- owned by postgres
> GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp;  -- looks generous, is not
> ```
>
> fails on the app's first migration with `ERROR: permission denied for schema
> public`. `GRANT ALL ON DATABASE` covers only CONNECT, TEMP and creating
> *schemas* — it says nothing about what is inside `public`. This worked before
> PostgreSQL 15, which is why it is easy to write from memory.

The app role deliberately cannot create roles or databases, read `pg_authid`,
or connect to another app's database. It also cannot install **untrusted**
extensions — PostGIS, TimescaleDB and `pg_stat_statements` need the superuser,
so add them next to the `pgcrypto` line above rather than leaving them to a
migration. Trusted ones (`pgcrypto`, `uuid-ossp`, `citext`, `hstore`,
`pg_trgm`, `ltree`, `unaccent`) the app can create for itself, so a
`CREATE EXTENSION IF NOT EXISTS` in a migration is safe.

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