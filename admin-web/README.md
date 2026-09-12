# VetCircuit Admin Web

Internal dashboard for the founding team, per the technical plan's admin app: onboard/verify vets, monitor circuits, handle disputes, view metrics. Talks to the same Supabase project as the customer and partner apps — every page is gated behind the `admins` table and the `is_admin()` RLS helper, so it's not a separate trust model bolted on top.

## Setup

```sh
cd admin-web
npm install
cp .env.example .env.local   # fill in your Supabase project URL + anon key
npm run dev
```

You also need at least one row in the `admins` table pointing at your own `auth.users` id — see `backend/supabase/migrations/0002_seed_admin.sql`. There's deliberately no self-service way to become an admin.

## Pages

- **Overview** — headline counts (customers, vets, pending verifications, circuits, active/completed visits, active subscriptions)
- **Vets** — approve/reject/reset a vet's manual verification status (the platform's real trust layer, per the plan — never automated)
- **Circuits** — read-only list of every circuit and its scheduled-slot count
- **Disputes** — visits rated 2★ or below, surfaced for manual follow-up (the cheapest signal before a dedicated ticketing system is worth building)

## Deploying

Same as the partner app — any Node host (Vercel is simplest). Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` as environment variables.
