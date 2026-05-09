import { createClient } from "@supabase/supabase-js";

// Server-side only — never import this in client components.
// C6 note: This env var should hold the service_role key (bypasses RLS).
// If using anon key instead, the save_month_schedule() RPC still works
// because it uses SECURITY DEFINER. Verify in Vercel env settings.
export function createSupabaseServer() {
  return createClient(
    process.env.SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!
  );
}
