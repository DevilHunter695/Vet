# VetCircuit

Two-sided marketplace connecting pet owners with vets/para-vets who run scheduled home-visit "circuits". This repo contains the customer-facing iOS app (Swift/SwiftUI) and the Supabase backend it talks to, per the technical plan.

## Repository layout

```
VetCircuit/            iOS app source (MVVM + Clean Architecture)
  App/                 App entry point, DI container, session state
  Presentation/        SwiftUI views + @Observable view models, by feature
  Domain/              Pure Swift models, use cases, repository protocols
  Data/                Network client, Supabase + mock repositories, SwiftData cache
  Resources/           Info.plist, app config
VetCircuitTests/       Unit tests for the Domain layer (use cases)
backend/supabase/
  migrations/          Postgres schema + Row Level Security policies
  functions/           Edge Functions (payment gateway webhook)
partner-web/           Vet/para-vet web dashboard (Next.js) — circuit + visits + notes
project.yml            XcodeGen spec — generates VetCircuit.xcodeproj
.github/workflows/     CI: build + test on every push/PR
```

## Getting started

### 1. Generate the Xcode project

The `.xcodeproj` is not checked in (avoids merge-conflict-prone generated XML). Generate it locally:

```sh
brew install xcodegen
xcodegen generate
open VetCircuit.xcodeproj
```

### 2. Backend (Supabase)

1. Create a free project at supabase.com.
2. Apply the schema: `supabase db push` (or paste `backend/supabase/migrations/0001_init.sql` into the SQL editor).
3. Deploy the payment webhook: `supabase functions deploy payment-webhook`, and set its secrets:
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `PAYMENT_GATEWAY_WEBHOOK_SECRET`
4. In Xcode, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` as build setting overrides (or an `.xcconfig` you don't commit) — they're read into `Info.plist` and surfaced via `AppConfig`.

### 3. Run

The app works out of the box against **in-memory mock repositories** (`Data/Repositories/MockRepositories.swift`) — no backend required to explore the UI. Once `SUPABASE_URL`/`SUPABASE_ANON_KEY` are set and the `Supabase` package resolves, wire `DependencyContainer` to the `Supabase*Repository` implementations in `SupabaseRepositories.swift`.

### 4. Tests

```sh
xcodebuild test -project VetCircuit.xcodeproj -scheme VetCircuit \
  -destination "platform=iOS Simulator,name=iPhone 16"
```

Domain-layer use cases (`Domain/UseCases`) are pure Swift and fully covered without touching the network or UI.

## Architecture

MVVM + Clean Architecture, per the technical plan:

```
Presentation (SwiftUI Views)  — dumb views, no business logic
ViewModels (@Observable)      — UI state, calls Use Cases
Domain (Use Cases + Models)   — pure Swift, zero framework imports
Data (Repositories)           — Supabase SDK / mocks, SwiftData cache, Keychain
```

## Security

- Row Level Security in Postgres is the real authorization boundary — a user cannot read another user's data even if they guess an ID.
- Auth tokens live in Keychain, never `UserDefaults`.
- No raw card data ever touches this app or its backend — checkout is delegated to a payment gateway's hosted page (`CheckoutWebView`), and payment success is only ever confirmed via a signature-verified server-to-server webhook (`backend/supabase/functions/payment-webhook`), never a client-reported status.
- See the technical plan's Section 5 checklist for the full list.

## What's implemented (MVP scope)

- Sign in with Apple + phone OTP auth
- Browse circuits/vets by area
- Book a single visit against an available schedule slot
- Subscribe to a recurring plan (checkout handoff)
- Visit status tracking (requested → confirmed → en route → completed)
- In-app text chat per visit
- Visit history with vet notes
- Rate & review after a completed visit
- Multi-pet profiles

## V2 (in progress)

- Live vet location tracking during "en route" (MapKit + polling/subscription abstraction, `Presentation/Tracking`)
- Quick call handoff from a visit (`StartCallUseCase` — stubbed via a web checkout-style handoff pending a real video SDK)
- Referral program: personal code, share sheet, invite by phone (`Presentation/Referral`)
- Push notification registration (APNs) + local subscription-renewal reminders (`App/PushNotificationManager.swift`)

Deliberately deferred to V3 per the plan: AI-assisted triage, multi-vertical support, loyalty/rewards, Apple Watch companion, Android app — see the technical plan for the full prioritization rationale.
