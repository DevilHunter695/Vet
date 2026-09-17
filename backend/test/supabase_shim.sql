-- Enough of Supabase's managed surface for the migrations to apply against a
-- stock Postgres, and no more.
--
-- The migrations reference things Supabase provides and a bare Postgres does
-- not: the `auth` schema (`auth.users`, `auth.uid()`), the `storage` schema
-- (`storage.objects`, `storage.foldername()`), and the `authenticated` role.
-- Without them `psql` fails on the first file and the schema can never be
-- exercised at all — which is how 61 migrations came to be written, reviewed
-- and never once executed.
--
-- This is a test harness, not a reimplementation. It asserts nothing about how
-- Supabase behaves; it exists so the *migrations'* own SQL — syntax, column
-- types, constraints, function bodies, trigger definitions, policy
-- expressions — is checked by the same engine that will eventually run it.
-- A migration that applies here can still be wrong about authorization; one
-- that fails here is wrong, full stop.

create extension if not exists "pgcrypto";

-- Roles are created by the runner before this file, because they are
-- cluster-wide rather than per-database and a second run would fail on them
-- already existing.

create schema if not exists auth;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text
);

-- Returns null, which is what an unauthenticated session gets. The policies
-- that call it are being checked for *validity* here, not for behaviour.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon');
$$;

create schema if not exists storage;

create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text,
  name text,
  owner uuid
);

-- Supabase's helper: splits an object path into its folder components.
create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $$
  select string_to_array(regexp_replace(name, '/[^/]*$', ''), '/');
$$;

-- Supabase creates this publication and Realtime streams whatever is added to
-- it. A migration that adds a table to it is correct; bare Postgres just has
-- no such publication, so the harness makes one. `for all tables` is not used
-- deliberately — then `alter publication ... add table` would fail, and the
-- point is to exercise the statement the migration actually runs.
create publication supabase_realtime;
