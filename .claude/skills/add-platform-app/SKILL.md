---
name: add-platform-app
description: Add a new service to the kovostack platform stack — base compose entry, per-app override file, Postgres database, env vars, and docs. Use whenever a new app/container is being added to this repo, or when an existing app needs a new secret or database.
---

# Adding an app to the platform

Every addition touches the same eight places. Missing one is the usual failure
mode: the app starts but has no volumes, or Compose refuses to render because a
variable is undefined.

## Checklist

1. **`docker-compose.yml`** — add the service to the base file: image as
   `${MYAPP_VERSION:-<tag>}`, `container_name: platform-myapp`,
   `restart: unless-stopped`, `networks: [platform]`, a healthcheck if the
   image has a shell, and `depends_on` with `condition: service_healthy` for
   Postgres/Redis. Required secrets use `${VAR:?set VAR in .env}`.

2. **`myapp/compose.override.yml`** — host wiring only: bind mounts, published
   ports (`127.0.0.1:${MYAPP_PORT:-nnnn}:nnnn`), json-file logging with
   `max-size: 10m` / `max-file: 3`. Start the file with the reminder that
   **relative paths resolve against the repo root**, so write `./myapp/data`.

   To publish it over TLS, add three env vars here — `VIRTUAL_HOST:
   ${MYAPP_HOST:?...}`, `VIRTUAL_PORT`, `LETSENCRYPT_HOST: ${MYAPP_HOST}`.
   nginx-proxy and acme-companion pick it up from the Docker socket. The
   hostname must already resolve to the VM, or ACME fails. If the app takes
   large uploads, add
   `./proxy/vhost.d/myapp:/etc/nginx/vhost.d/${MYAPP_HOST}:ro` to
   `proxy/compose.override.yml` — the global default caps bodies at 64 MB.

3. **`edge/sni.conf.stream-template`** (only for an app with a public
   hostname) — add `${MYAPP_HOST}    proxy:443;` to the SNI map, and pass
   `MYAPP_HOST` into the `edge` service's `environment:` in the base compose.
   The edge routes any name it does not recognise to the Kubernetes cluster,
   so without this line the app's TLS traffic never reaches nginx-proxy and
   the failure looks like a certificate problem. `make check-edge` prints the
   rendered map.

4. **`COMPOSE_FILE` in `.env.example`** — append
   `:myapp/compose.override.yml`. Skipping this is silent; the app runs
   volume-less.

5. **Database** (if it needs one) — add
   `create_app_db "myapp" "${MYAPP_DB_PASSWORD:-}"` to
   `postgres/init/01-init-databases.sh`, and pass `MYAPP_DB_PASSWORD` into the
   `postgres` service's `environment:` in the base compose. Remind the user
   that this script only runs on an empty `postgres/data`; on a live cluster
   they must also run the SQL from the README's "Adding a new app database".

   Copy that SQL rather than writing it from memory: the `OWNER myapp` clause
   is what lets the app's own migrations create tables (PostgreSQL 15+ gives
   the `public` schema to `pg_database_owner`, so granting privileges on the
   database instead fails at the first `CREATE TABLE` with `permission denied
   for schema public`). Any **untrusted** extension the app needs — PostGIS,
   TimescaleDB, `pg_stat_statements` — must go in the superuser block there
   too; trusted ones the app can create for itself.

6. **`.env.example`** — a commented block for the app: port, version, and each
   secret as an empty value with `# CHANGE ME — <generation command>`.

7. **`README.md`** — a row in the stack table and one row per variable in the
   values table (Required / How to generate / Notes).

8. **`.gitignore`** — add `myapp/data` (and any generated credential file).

## Then verify

```bash
make check                  # renders the merged config, catches missing vars
docker compose config | grep -A5 'myapp:'
```

Confirm the volume paths in the rendered output are absolute and point inside
the repo — that is the check that catches mistake #2.

## Conventions to match

- Passwords stay alphanumeric (`openssl rand -hex 24`) — they go into
  connection URLs.
- Services reach each other by service name on `platform-network`; host
  publishing is loopback-only, for humans.
- Comments explain *why*, not *what*; blank line between services.