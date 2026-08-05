# CLAUDE.md

Context for working in this repo. Read this before exploring — it covers the
layout, the non-obvious rules, and the mistakes that are easy to make here.

## What this repo is

GitOps repo for the **platform layer** of one VM: Docker Compose + config for
shared services (Postgres, Redis, zot registry, Infisical secrets). A Kubernetes
cluster on the same VM consumes these services, but all k8s manifests, Helm
charts and Argo CD config live in a **separate repo** — never add them here.

There is no application source code, no build, no test suite. Changes are
config; the way to validate them is `docker compose config` / `make check`.

## Layout

```
docker-compose.yml               base topology: images, env, network, healthchecks
<app>/compose.override.yml       host wiring: bind mounts, ports, logging
<app>/config/                    committed config files
<app>/data/                      runtime state — git-ignored, never touch
edge/sni.conf.stream-template    L4 SNI routing table (envsubst at container start)
proxy/conf.d/                    hand-written server blocks, numeric prefixes matter
postgres/init/                   first-boot SQL/shell, one role+db per app
.env.example                     every hand-set value, documented
Makefile                         day-to-day commands
```

Apps: `edge` (plain nginx, L4), `proxy` (nginx-proxy) + `acme`
(acme-companion), `postgres`, `redis`, `zot`, `infisical`.

## The edge

`edge` owns host 80/443 and splits traffic between this platform and the k3s
cluster on the same VM (whose manifests live in the other repo):

- **:443** routed by TLS SNI, decrypting nothing. `REGISTRY_HOST`/`SECRETS_HOST`
  → `proxy:443`; **everything else → the cluster's Traefik NodePort 30443**,
  where cert-manager owns the certificate. The cluster is the default, the
  platform is the exception list.
- **:80** has no SNI to route on, so all of it goes to `proxy:80`, and
  `proxy/conf.d/00-cluster.conf` forwards non-platform hosts to NodePort 30080.
  That is the path cert-manager's HTTP-01 challenges take.

## Non-obvious rules

- **Overrides are chained via `COMPOSE_FILE` in `.env`**, not by Compose's
  automatic `docker-compose.override.yml` discovery (that only works for a file
  in the project root). A new app needs its override appended to `COMPOSE_FILE`
  in `.env.example`, or it silently runs without volumes.
- **Relative paths in `<app>/compose.override.yml` resolve against the repo
  root**, because the project directory is the first `-f` file's directory. So
  `./zot/data`, never `./data`.
- **`postgres/init/*` runs only when `postgres/data` is empty.** Editing it does
  nothing to a running cluster; live changes need manual SQL as well.
- **A new database must be created `OWNER <app>`, not granted to it.** Since
  PostgreSQL 15 the `public` schema is owned by `pg_database_owner` and PUBLIC
  has no `CREATE` on it, so ownership is what lets the app's migrations create
  tables. `CREATE DATABASE x; GRANT ALL PRIVILEGES ON DATABASE x TO x;` looks
  equivalent and fails at the first `CREATE TABLE` with `permission denied for
  schema public`. Untrusted extensions (PostGIS, TimescaleDB,
  `pg_stat_statements`) still need the superuser; trusted ones (`pgcrypto`,
  `uuid-ossp`, `citext`, `pg_trgm`, …) the app can create itself.
- **zot's UI only exists in the full image** (`zot-linux-amd64`). Never switch
  to `zot-minimal-*` — it drops `extensions.ui`/`search` and the UI 404s.
- **The zot image is distroless** — no shell, no curl. Don't add a healthcheck
  or try `docker compose exec zot sh`.
- **Infisical requires Redis.** It is not an optional cache; the queues break
  without it.
- **zot exits if `zot/config/htpasswd` is missing** — auth is configured, so a
  missing file is a startup error, not a fallback to anonymous. Create it
  before the first `make up`.
- **The platform's TLS belongs to this layer, not to Kubernetes.** Never
  suggest fronting *these* services with the cluster's ingress: the cluster
  pulls its images from zot, so that dependency is circular. The edge here owns
  host 80/443, which means k3s must be installed with `--disable=traefik
  --disable=servicelb`. Cluster workloads are the opposite case — their TLS is
  passed through untouched and cert-manager issues it.
- **Exposing a platform service = two env vars** on it (`VIRTUAL_HOST`,
  `VIRTUAL_PORT`) plus `LETSENCRYPT_HOST` — *and* a line in the SNI map in
  `edge/sni.conf.stream-template`. Without that line the edge sends the
  hostname to Kubernetes and nginx-proxy never sees it. Exposing a *cluster*
  app needs nothing here at all.
- **`edge/sni.conf.stream-template` must keep the double extension.** The nginx
  entrypoint strips only `.stream-template`, and the generated wrapper includes
  `stream-conf.d/*.conf` — a file named `sni.stream-template` renders to `sni`,
  is not included, and nginx starts happily with no stream config while
  refusing every connection. `nginx -t` does not catch this; `make check-edge`
  does.
- **The numeric prefixes in `proxy/conf.d/` are load-bearing.** nginx makes the
  first server block for a port the default server, nginx-proxy deliberately
  marks none, and `conf.d/*.conf` is included alphabetically — `00-cluster.conf`
  is the port-80 catch-all only because it sorts before the generated
  `default.conf`.
- **Everything on the proxy's 80/443 speaks PROXY protocol.**
  `ENABLE_PROXY_PROTOCOL` is global, so it applies to both listeners: any
  hand-written server block there needs `proxy_protocol` on its `listen` or
  nginx refuses to start, the client address is `$proxy_protocol_addr` and not
  `$remote_addr`, and healthchecks cannot use curl against port 80 — hence the
  plaintext loopback port in `proxy/conf.d/10-health.conf`.
- **Never give the proxy published ports again.** Host 80/443 belong to the
  edge; republishing them bypasses the SNI router and breaks the PROXY
  handshake.
- **`cluster-ingress` is an /etc/hosts entry, not DNS.** The nginx-proxy image
  has no envsubst, so `CLUSTER_INGRESS_IP` reaches it through `extra_hosts`.
  Changing that value needs `--force-recreate proxy`, not a reload. The
  NodePorts 30080/30443 are hardcoded in `edge/sni.conf.stream-template` and
  `proxy/conf.d/00-cluster.conf` — change both or neither.
- **`CLUSTER_INGRESS_IP` is never `127.0.0.1`**: k3s runs in the host's network
  namespace and these containers do not. Under rootless Docker the host's
  loopback is unreachable from a container at all — use the VM's routable
  address. `make cluster-check` probes the candidates.
- **acme-companion finds the proxy by the `com.github.nginx-proxy.nginx`
  label**, deliberately not by `NGINX_PROXY_CONTAINER`. The env var is trusted
  without an existence check, so it converts a clear error into the misleading
  "can't get docker-gen container id". Don't reintroduce it.
- **The VM runs rootless Docker.** `DOCKER_HOST_PATH` must point at
  `/run/user/<uid>/docker.sock`; `/var/run/docker.sock` also exists but belongs
  to the rootful daemon and is unreadable from these containers. Rootless also
  cannot bind ports <1024 without
  `net.ipv4.ip_unprivileged_port_start=0`. `make doctor` checks both — run it
  before debugging any proxy or certificate problem.
- **Large uploads need per-vhost nginx config.** `proxy/vhost.d/<hostname>`;
  the registry one sets `client_max_body_size 0` because nginx's 1 MB default
  rejects image layers.
- **Passwords must be alphanumeric.** `POSTGRES_PASSWORD`, `REDIS_PASSWORD` and
  `INFISICAL_DB_PASSWORD` are interpolated into connection URLs where `@ : / #`
  would need percent-encoding.
- Required env vars use `${VAR:?message}` so Compose fails fast. Keep that
  pattern for anything without a safe default.
- **Never put an inline comment after an empty value in `.env.example`.**
  Compose strips a trailing comment only when a value precedes it, so
  `FOO=   # CHANGE ME` sets `FOO` to `"# CHANGE ME"` — non-empty, so
  `${FOO:?}` does not fire and the placeholder text ends up as a hostname or a
  password. Put the comment on the line above.
- Image tags are `${X_VERSION:-default}` variables — pin in `.env`, don't
  hardcode in the compose.

## Secrets

Never commit: `.env`, `zot/config/htpasswd`, anything under `*/data`. All are
git-ignored — verify with `git check-ignore -v <path>` before adding files.

When adding a secret: put it in `.env.example` (empty value + `# CHANGE ME —
<generation command>`), add a row to the README value table, and wire it into
the compose. Those three always change together.

`INFISICAL_ENCRYPTION_KEY` is a one-way door — changing it makes every stored
secret unreadable. Flag this if a change would touch it.

## Common commands

```bash
make check          # docker compose config --quiet
make check-edge     # render + validate the SNI map with the real hostnames
make cluster-check  # are the ingress NodePorts reachable from a container?
make up / down / ps
make logs S=infisical
make psql DB=infisical
make zot-user U=ci P=pw
make secrets        # generate a fresh set of values
```

Public: the edge on 80/443 only — no other container publishes a public port.
Loopback (admin/tunnels): postgres 5432, zot 5000 (registry + UI), infisical
8080. Internally services use `postgres:5432`, `redis:6379`, `zot:5000` on
`platform-network`.

Docker treats `127.0.0.0/8` as insecure-by-default, so `localhost:5000` pushes
work without TLS — that is the bootstrap path and the fallback when certs are
broken. Never suggest `insecure-registries` for a non-loopback address.

## Style

- YAML: 2-space indent, blank line between services, comments explain *why*.
- Comment the surprising parts only — the files are already dense with them.
- Keep `.env.example`, `README.md` value table, and `docker-compose.yml` in
  sync. A drift between those three is the most likely bug in this repo.