#!/bin/bash
# Creates one role + one database per platform app ("database per app").
#
# Runs ONLY on the very first start, while ./postgres/data is still empty.
# Adding an app here later does nothing to an existing cluster — create it by
# hand instead (see README, "Adding a new app database").
#
# Passwords come from the environment, so they never end up in git.

set -euo pipefail

psql_super() {
    local db="$1"
    shift
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" "$@"
}

# create_app_db <name> <password>
#
# The role owns its own database and nothing else: it cannot read or write
# any other app's data. Idempotent, so it is safe to re-run by hand.
create_app_db() {
    local db="$1"
    local password="$2"

    if [ -z "$password" ]; then
        echo "init: skipping database '$db' — no password provided" >&2
        return 0
    fi

    echo "init: creating role and database '$db'"

    psql_super postgres -v db="$db" -v password="$password" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db', :'password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db');
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'db')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db');
\gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db');
\gexec
EOSQL

    # Extensions need superuser, so they are installed here rather than left
    # to the app's own migrations.
    psql_super "$db" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
EOSQL
}

# --- platform apps -----------------------------------------------------
# One line per app. Add the matching *_DB_PASSWORD to .env.example, to .env
# on the server, and pass it through in docker-compose.yml.

create_app_db "infisical" "${INFISICAL_DB_PASSWORD:-}"
create_app_db "kovospace" "${KOVOSPACE_DB_PASSWORD:-}"
create_app_db "paster" "${PASTER_DB_PASSWORD:-}"

echo "init: done"