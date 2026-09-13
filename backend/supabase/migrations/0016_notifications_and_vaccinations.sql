-- N3 (lifecycle pushes) + plan §5's `notifications` table, not yet created by
-- any prior migration. Rows are queued (sent_at null) by the
-- lifecycle-notifications Edge Function on a schedule (§6.5); an actual
-- push-sending job to drain this queue is out of scope here.

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  category text not null check (category in (
    'booking_update', 'chat_message', 'vaccination_due', 'renewal_due',
    'dormant_winback', 'abandoned_cart', 'promotion'
  )),
  title text not null,
  body text not null,
  sent_at timestamptz, -- null = queued, not yet delivered
  created_at timestamptz not null default now()
);

create index notifications_user_id_idx on notifications(user_id);
-- The lifecycle job's dedupe check (§6.5: don't re-queue the same reminder
-- every run) scans unsent rows per user/category — index that access path.
create index notifications_unsent_idx on notifications(user_id, category) where sent_at is null;

alter table notifications enable row level security;

create policy "notifications read own" on notifications for select
  using (user_id = auth.uid() or is_admin());

-- No client insert/update policy: only the service role (Edge Functions) may
-- write here — a customer marking their own reminders "sent" makes no sense.

-- Minimal vaccination-tracking table the N3 job reads from. A real deployment
-- populates this from visit notes/records (plan §I — visit checklist); here
-- it's the structural piece lifecycle-notifications needs to exist at all.
create table vaccinations (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references pets(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  vaccine_name text not null,
  administered_at timestamptz,
  next_due_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index vaccinations_next_due_idx on vaccinations(next_due_at);

alter table vaccinations enable row level security;

create policy "vaccinations all own" on vaccinations for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());
