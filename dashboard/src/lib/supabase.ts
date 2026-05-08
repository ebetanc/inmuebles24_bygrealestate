import { createClient } from "@supabase/supabase-js";

// Server-side only — never import this in client components
export function createSupabaseServer() {
  return createClient(
    process.env.SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!
  );
}
