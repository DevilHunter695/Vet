-- E1: "change quantity" on a cart line — repeat the same service/variant/pet
-- combination N times (distinct from D6's multi-pet, which is petIds on one
-- visit). Additive column only, default 1 so existing rows are unaffected.
alter table cart_items add column if not exists quantity integer not null default 1 check (quantity between 1 and 20);
