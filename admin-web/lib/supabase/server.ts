import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Server-side Supabase client, run as the signed-in admin — RLS's `is_admin()`
// helper (backend/supabase/migrations/0001_init.sql) is what actually grants
// the broader read/write access; this client carries no elevated privilege
// of its own.
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            );
          } catch {
            // Called from a Server Component with no request context to
            // mutate — safe to ignore since middleware refreshes sessions.
          }
        },
      },
    }
  );
}
