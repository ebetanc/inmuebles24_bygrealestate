import { createClient } from "@supabase/supabase-js";

// Server-side only — never import this in client components.
// This client requires the service_role key (bypasses RLS).
// save_month_schedule() uses SECURITY INVOKER; anon and authenticated cannot execute it.
export function createSupabaseServer() {
  return createClient(
    process.env.SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!
  );
}
