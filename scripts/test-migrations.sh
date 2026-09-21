#!/usr/bin/env bash
# Apply every migration to a throwaway Postgres and run the SQL behaviour
# tests against it.
#
# The app runs on mock repositories, so nothing in the Swift test suite ever
# touches this schema: 462 unit tests can be green while book_visit() is
# broken. This closes that gap without needing a Supabase project.
#
# Usage: scripts/test-migrations.sh          (starts its own throwaway server)
#        DATABASE_URL=... scripts/test-migrations.sh   (use an existing one)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$REPO_ROOT/backend/supabase/migrations"
TESTS="$REPO_ROOT/backend/supabase/tests"

# Scratch space for error logs. Set here so it exists on both paths — the
# throwaway-server branch below reassigns it to the server's own directory.
WORK="$(mktemp -d)"
CLEANUP_SERVER=0

if [ -n "${DATABASE_URL:-}" ]; then
  PSQL=(psql "$DATABASE_URL")
else
  PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
  [ -x "$PGBIN/initdb" ] || { echo "No Postgres server binaries found; set PGBIN or DATABASE_URL." >&2; exit 2; }
  rmdir "$WORK" 2>/dev/null || true
  WORK="$(mktemp -d)"
  CLEANUP_SERVER=1
  # initdb refuses to run as root, so drop to an unprivileged user when needed.
  RUNAS=""
  if [ "$(id -u)" = 0 ]; then
    id -u pgtest >/dev/null 2>&1 || useradd -m pgtest
    RUNAS="pgtest"
    chmod 755 "$WORK"
    chown -R pgtest "$WORK"
  fi
  run() { if [ -n "$RUNAS" ]; then su "$RUNAS" -c "$1"; else bash -c "$1"; fi; }
  run "$PGBIN/initdb -U postgres -A trust $WORK/data" >/dev/null
  run "$PGBIN/pg_ctl -D $WORK/data -o '-k $WORK -c listen_addresses=' -l $WORK/pg.log start" >/dev/null
  trap 'run "$PGBIN/pg_ctl -D $WORK/data stop -m immediate" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
  PSQL=(psql -h "$WORK" -U postgres -d migtest)
  psql -h "$WORK" -U postgres -q -c "create database migtest;"
fi
if [ "$CLEANUP_SERVER" -eq 0 ]; then
  trap 'rm -rf "$WORK"' EXIT
fi

# What Supabase provides that plain Postgres does not. `auth.uid()` is pinned
# to a fixed caller so the tests can assert on ownership checks.
"${PSQL[@]}" -q -v ON_ERROR_STOP=1 <<'SQL'
create extension if not exists pgcrypto;
create schema if not exists auth;
create schema if not exists extensions;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid language sql stable
  as $fn$ select '00000000-0000-0000-0000-000000000001'::uuid $fn$;
do $$ begin
  create role anon nologin; create role authenticated nologin;
  create role service_role nologin; create role supabase_auth_admin nologin;
exception when duplicate_object then null; end $$;
do $$ begin
  create publication supabase_realtime;
exception when duplicate_object then null; end $$;
SQL

applied=0
for f in "$MIGRATIONS"/*.sql; do
  if ! "${PSQL[@]}" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>"$WORK/err.log"; then
    echo "MIGRATION FAILED: $(basename "$f")" >&2
    grep -E "ERROR|LINE" "$WORK/err.log" | head -5 >&2
    exit 1
  fi
  applied=$((applied + 1))
done
echo "Applied $applied migrations cleanly."

for t in "$TESTS"/*.sql; do
  [ -e "$t" ] || continue
  echo "--- $(basename "$t")"
  "${PSQL[@]}" -q -v ON_ERROR_STOP=1 -f "$t"
done
echo "Schema tests passed."
