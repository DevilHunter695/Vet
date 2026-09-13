-- M1 (help centre), M2/K8 (support tickets, incl. per-visit disputes), and
-- J7 (notification centre read state) — the `notifications` table itself
-- already exists from 0019 (N3 lifecycle queue); this only extends it.

-- M1: FAQ content is public-read (browsable before sign-in, plan §C) and
-- admin-write only — the app is never the source of truth for its own copy,
-- mirroring `services` in 0003_catalog.sql.
create table help_articles (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in (
    'booking', 'cancellation', 'payment', 'pets', 'account', 'visits'
  )),
  question text not null,
  answer text not null,
  created_at timestamptz not null default now()
);

alter table help_articles enable row level security;

create policy "help_articles public read" on help_articles for select using (true);
create policy "help_articles admin write" on help_articles for all using (is_admin()) with check (is_admin());

-- M2/K8: a support ticket. `visit_id` set = "report a problem with this
-- visit" (a dispute); null = general "contact support". Owner can read and
-- insert; no update policy at all — once submitted, only ops (service role,
-- via the ops console) can move it through open/in_progress/resolved. This
-- mirrors 0009_refunds_and_invoices.sql's refunds table: the client reads
-- status, it never rewrites it.
create table support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  visit_id uuid references visits(id) on delete set null,
  subject text not null,
  body text not null,
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved')),
  created_at timestamptz not null default now()
);

create index support_tickets_user_id_idx on support_tickets(user_id);
create index support_tickets_visit_id_idx on support_tickets(visit_id) where visit_id is not null;

alter table support_tickets enable row level security;

create policy "support_tickets select own" on support_tickets for select
  using (user_id = auth.uid() or is_admin());

create policy "support_tickets insert own" on support_tickets for insert
  with check (user_id = auth.uid());

-- No update/delete policy for customers — status changes are an ops action
-- taken from the admin console, which runs under a service role that
-- bypasses RLS, exactly like refund issuance.
create policy "support_tickets admin update" on support_tickets for update
  using (is_admin()) with check (is_admin());

-- J7: notification centre read/unread. 0019 created `notifications` with no
-- client write policy at all (queued rows are service-role-only); reading a
-- notification in-app needs a narrow way to flip *only* read_at on your own
-- row, so this adds the column plus a scoped update policy rather than
-- opening the table to general client writes.
alter table notifications add column read_at timestamptz;

create policy "notifications mark own read" on notifications for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
