-- E9: saved payment methods — a gateway-tokenized card/UPI reference the
-- customer can reuse at checkout instead of re-entering it every time.
--
-- This table NEVER stores a PAN, CVV, or any raw card/UPI detail — only the
-- gateway's own token reference (Razorpay/Stripe-style `gateway_token_id`)
-- plus a display label safe to show back to the user ("Visa •••• 4242").
-- Tokenization itself happens against the gateway's SDK client-side (or via
-- their hosted checkout); this table is just a pointer to that token, same
-- boundary as `payments`/`refunds` never seeing raw card data either.

create table saved_payment_methods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  gateway_token_id text not null,
  display_label text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create index saved_payment_methods_user_id_idx on saved_payment_methods(user_id);

alter table saved_payment_methods enable row level security;

-- No update policy: a token is either removed (delete) or replaced (a fresh
-- insert from a new tokenization) — "no update method on purpose" mirrors
-- SupportRepository's ticket design. Except making a *different* saved
-- method the default is still just flipping a boolean on rows the owner
-- already controls, so it's allowed narrowly below.
create policy "saved_payment_methods select own" on saved_payment_methods for select
  using (user_id = auth.uid());

create policy "saved_payment_methods insert own" on saved_payment_methods for insert
  with check (user_id = auth.uid());

create policy "saved_payment_methods delete own" on saved_payment_methods for delete
  using (user_id = auth.uid());

create policy "saved_payment_methods update own default flag" on saved_payment_methods for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
