-- E6: "an order must reference a valid quote" — payments is this app's order
-- table (there is no separate orders entity). Additive, nullable: the
-- subscription/tip checkout paths don't go through a cart quote at all.
alter table payments add column if not exists quote_id uuid references quotes(id);
