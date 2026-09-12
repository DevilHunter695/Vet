# VetCircuit Partner Web

Bare-bones Next.js dashboard for vets/para-vets, per the technical plan's Phase 3 ("Simple partner app or even a web dashboard for vets to: see their circuit schedule, accept/complete visits, log notes"). Talks directly to the same Supabase project as the iOS app — Row Level Security is the shared authorization layer, so a vet can only ever see and modify their own circuit and visits.

## Setup

```sh
cd partner-web
npm install
cp .env.example .env.local   # fill in your Supabase project URL + anon key
npm run dev
```

## What it does

- Email/password sign-in (a vet's `auth.users` row must have a matching row in `vets` with `auth_id` set — done manually during onboarding/verification, per the plan's trust model)
- Shows the vet's circuit(s) and schedule slot count
- Lists visits, lets the vet walk each one through `requested → confirmed → en_route → completed`, log notes on completion, or cancel
- Nothing here writes payment or review data — those stay owner-only per RLS

## Deploying

Any Node host works (Vercel is the path of least resistance for a Next.js app). Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` as environment variables on the host.
