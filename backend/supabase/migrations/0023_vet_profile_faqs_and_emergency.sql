-- C3/C5: vet profile fields the discovery filter sheet and vet detail screen
-- both need — "Hindi-speaking", "female vet", "handles cats" are real filters
-- in this market (plan §C3), not nice-to-haves.
-- C6: FAQs on a service, the one piece of the C6 detail screen that wasn't
-- already built.
-- C11: a public-read 24x7 emergency clinic directory for the emergency path.

alter table vets
  add column bio text,
  add column years_of_experience integer check (years_of_experience is null or years_of_experience >= 0),
  add column languages text[] not null default '{}',
  add column gender text check (gender in ('male', 'female', 'other')),
  add column species_handled text[] not null default '{dog,cat,bird,other}';

create table faqs (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  question text not null,
  answer text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index faqs_service_id_idx on faqs(service_id);

alter table faqs enable row level security;

-- Same public-read/admin-write shape as the rest of the catalog
-- (0003_catalog.sql) — FAQs are ops-managed content, not user-generated.
create policy "faqs public read" on faqs for select using (true);
create policy "faqs admin write" on faqs for all using (is_admin()) with check (is_admin());

create table emergency_clinics (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  phone text not null,
  latitude double precision not null,
  longitude double precision not null,
  is_open_24x7 boolean not null default true,
  created_at timestamptz not null default now()
);

alter table emergency_clinics enable row level security;

-- C11 is safety-critical and reachable before sign-in (a customer in a panic
-- shouldn't have to log in first) — public read, same as app_config
-- (0018_notification_preferences_and_app_config.sql).
create policy "emergency_clinics public read" on emergency_clinics for select using (true);
create policy "emergency_clinics admin write" on emergency_clinics for all using (is_admin()) with check (is_admin());
