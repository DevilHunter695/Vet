-- J8: transactional SMS/WhatsApp fallback when push fails.
--
-- This table is a record of *intent* to send a transactional SMS/WhatsApp
-- fallback, written only by the `send-sms-fallback` Edge Function
-- (service-role) — there is no third-party gateway (Twilio/MSG91/etc)
-- account wired into this codebase, so no actual text is ever sent from
-- here; see that function's source for exactly where a real gateway API
-- call would go. Append-only, mirroring wallet_ledger's discipline
-- (0026_wallet_ledger.sql): no update/delete policy for anyone.

create table sms_fallback_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  phone text not null,
  category text not null,
  body text not null,
  -- Why push wasn't used: no_push_token | push_delivery_failed | push_disabled_by_user
  -- (mirrors NotificationDeliveryDecision.FallbackReason on the client).
  reason text not null check (reason in ('no_push_token', 'push_delivery_failed', 'push_disabled_by_user')),
  created_at timestamptz not null default now()
);

alter table sms_fallback_log enable row level security;

-- A user may read their own fallback log (parity with `notifications`'s
-- "you can see what was sent to you"); nobody, including the row's own
-- user, may insert/update/delete directly — only the service-role Edge
-- Function writes here.
create policy "sms_fallback_log select own" on sms_fallback_log for select
  using (user_id = auth.uid());

create index sms_fallback_log_user_id_idx on sms_fallback_log (user_id);
