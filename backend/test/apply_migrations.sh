#!/usr/bin/env bash
# Applies every migration, in order, to a throwaway Postgres.
#
# The point is narrow and worth stating plainly: it proves the SQL is valid and
# the schema builds. It does not prove the app works against it, and it cannot
# check RLS behaviour, since the harness's auth.uid() always returns null.
#
# What it does catch is the class of mistake that is otherwise invisible until
# someone runs a real deploy: a typo, a column that does not exist, a function
# body that will not parse, a trigger on a missing table, a constraint that
# contradicts an earlier one, or a migration that depends on one applied after
# it.
set -euo pipefail

DB="${1:-vetcircuit_migration_test}"
MIGRATIONS_DIR="$(cd "$(dirname "$0")/../supabase/migrations" && pwd)"
SHIM="$(cd "$(dirname "$0")" && pwd)/supabase_shim.sql"

psql -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" postgres
psql -v ON_ERROR_STOP=1 -q -c "create database $DB" postgres

# Roles are cluster-wide, so a re-run must not fail on them already existing.
psql -v ON_ERROR_STOP=1 -q -d "$DB" <<'PRE' || true
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
end $$;
PRE

echo "--- applying harness shim"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SHIM" \
  | grep -v '^CREATE ROLE$' || true

applied=0
for file in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
  name="$(basename "$file")"
  if ! psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$file" > /tmp/migration_out.txt 2>&1; then
    echo "FAILED: $name"
    echo "-----------------------------------------"
    cat /tmp/migration_out.txt
    echo "-----------------------------------------"
    exit 1
  fi
  applied=$((applied + 1))
  echo "ok  $name"
done

echo
echo "--- exercising D6's trigger against the built schema"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$(cd "$(dirname "$0")" && pwd)/verify_d6.sql"

echo
echo "=========== MIGRATION VERDICT ==========="
echo "  applied: $applied migrations, 0 failures"
psql -tA -d "$DB" -c \
  "select '  tables : ' || count(*) from information_schema.tables where table_schema = 'public'"
psql -tA -d "$DB" -c \
  "select '  funcs  : ' || count(*) from information_schema.routines where routine_schema = 'public'"
psql -tA -d "$DB" -c \
  "select '  policies: ' || count(*) from pg_policies where schemaname = 'public'"
echo "========================================="
