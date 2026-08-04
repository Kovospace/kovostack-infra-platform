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
postgres/init/                   first-boot SQL/shell, one role+db per app
.env.example                     every hand-set value, documented
Makefile                         day-to-day commands
```

Apps: `proxy` (nginx-proxy) + `acme` (acme-companion), `postgres`, `redis`,
`zot`, `infisical`.

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
- **zot's UI only exists in the full image** (`zot-linux-amd64`). Never switch
  to `zot-minimal-*` — it drops `extensions.ui`/`search` and the UI 404s.
- **The zot image is distroless** — no shell, no curl. Don't add a healthcheck
  or try `docker compose exec zot sh`.
- **Infisical requires Redis.** It is not an optional cache; the queues break
  without it.
- **zot exits if `zot/config/htpasswd` is missing** — auth is configured, so a
  missing file is a startup error, not a fallback to anonymous. Create it
  before the first `make up`.
- **TLS belongs to this layer, not to Kubernetes.** Never suggest fronting
  these services with the cluster's ingress: the cluster pulls its images from
  zot, so that dependency is circular. The proxy here owns host 80/443, which
  means k3s must be installed with `--disable=traefik --disable=servicelb`.
- **Exposing a service = two env vars** on it (`VIRTUAL_HOST`, `VIRTUAL_PORT`)
  plus `LETSENCRYPT_HOST`. nginx-proxy discovers it over the Docker socket;
  there is no central vhost file to edit.
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
make up / down / ps
make logs S=infisical
make psql DB=infisical
make zot-user U=ci P=pw
make secrets        # generate a fresh set of values
```

Public: the proxy on 80/443 only. Loopback (admin/tunnels): postgres 5432, zot
5000 (registry + UI), infisical 8080. Internally services use `postgres:5432`,
`redis:6379`, `zot:5000` on `platform-network`.

Docker treats `127.0.0.0/8` as insecure-by-default, so `localhost:5000` pushes
work without TLS — that is the bootstrap path and the fallback when certs are
broken. Never suggest `insecure-registries` for a non-loopback address.

## Style

- YAML: 2-space indent, blank line between services, comments explain *why*.
- Comment the surprising parts only — the files are already dense with them.
- Keep `.env.example`, `README.md` value table, and `docker-compose.yml` in
  sync. A drift between those three is the most likely bug in this repo.