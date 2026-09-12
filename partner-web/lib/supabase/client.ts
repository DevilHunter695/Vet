"use client";

import { createBrowserClient } from "@supabase/ssr";

// Browser-side Supabase client. Only the anon key is used here — Row Level
// Security in Postgres (backend/supabase/migrations/0001_init.sql) is what
// actually stops a vet from reading another vet's circuits or visits.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
