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

Apps: `postgres`, `redis`, `zot`, `infisical`.

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

Ports (all `127.0.0.1` only): postgres 5432, zot 5000 (registry + UI),
infisical 8080. Internally services use `postgres:5432`, `redis:6379`,
`zot:5000` on `platform-network`.

## Style

- YAML: 2-space indent, blank line between services, comments explain *why*.
- Comment the surprising parts only — the files are already dense with them.
- Keep `.env.example`, `README.md` value table, and `docker-compose.yml` in
  sync. A drift between those three is the most likely bug in this repo.