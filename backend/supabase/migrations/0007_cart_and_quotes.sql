-- E: server-side cart + server-authoritative quote engine (Appendix C).
-- The client sends only selections; every rupee amount the app ever shows
-- comes back from create_quote(), never computed locally.

create table carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references users(id) on delete cascade,
  address_id uuid references addresses(id) on delete set null,
  circuit_id uuid references circuits(id) on delete set null,
  slot_id uuid references schedule_slots(id) on delete set null,
  coupon_code text,
  updated_at timestamptz not null default now()
);

create table cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references carts(id) on delete cascade,
  service_id uuid not null references services(id) on delete restrict,
  variant_id uuid not null references service_variants(id) on delete restrict,
  pet_ids uuid[] not null check (array_length(pet_ids, 1) > 0),
  addon_ids uuid[] not null default '{}'
);

create index cart_items_cart_id_idx on cart_items(cart_id);

create table quotes (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references carts(id) on delete cascade,
  breakdown jsonb not null,
  total_minor_units integer not null check (total_minor_units >= 0),
  signature text not null, -- HMAC-SHA256 of (cart snapshot + total), server secret only
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index quotes_cart_id_idx on quotes(cart_id);

alter table carts enable row level security;
alter table cart_items enable row level security;
alter table quotes enable row level security;

create policy "carts all own" on carts for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

create policy "cart_items all own" on cart_items for all
  using (exists (select 1 from carts c where c.id = cart_id and (c.user_id = auth.uid() or is_admin())))
  with check (exists (select 1 from carts c where c.id = cart_id and c.user_id = auth.uid()));

-- Quotes are created only by the create_quote() Edge Function (service role)
-- — a customer can read their own quotes but never insert/update one
-- directly, since that would let them set their own price.
create policy "quotes select own" on quotes for select
  using (exists (select 1 from carts c where c.id = cart_id and (c.user_id = auth.uid() or is_admin())));
