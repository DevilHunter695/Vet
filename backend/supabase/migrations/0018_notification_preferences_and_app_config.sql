-- O1: per-category notification preferences. Owner-only — nobody else
-- (including ops) needs to read another user's push settings.

create table notification_preferences (
  user_id uuid primary key references users(id) on delete cascade,
  booking_updates boolean not null default true,
  chat_messages boolean not null default true,
  vaccination_reminders boolean not null default true,
  promotions boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table notification_preferences enable row level security;

create policy "notification_preferences all own" on notification_preferences for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- O7/O8: server-driven kill switches — plan §7 calls force-upgrade "your only
-- true rollback lever for a shipped binary". Modeled as a single row (id = 1)
-- rather than a key/value table: the client always wants the whole config in
-- one round trip, and there is exactly one deployed app to gate.
create table app_config (
  id integer primary key default 1 check (id = 1),
  min_supported_version text not null default '1.0',
  is_maintenance_mode boolean not null default false,
  maintenance_message text,
  updated_at timestamptz not null default now()
);

insert into app_config (id, min_supported_version, is_maintenance_mode) values (1, '1.0', false);

alter table app_config enable row level security;

-- Public read, no auth required: a signed-out device on a killed binary must
-- still be told to update before it ever reaches sign-in (mirrors the
-- catalog's public-read pattern in 0003_catalog.sql).
create policy "app_config public read" on app_config for select using (true);
create policy "app_config admin write" on app_config for all using (is_admin()) with check (is_admin());
