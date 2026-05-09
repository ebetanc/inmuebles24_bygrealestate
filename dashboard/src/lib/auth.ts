import { createHash } from "crypto";

export const SESSION_COOKIE = "dashboard_session";

export function generateSessionToken(password: string): string {
  return createHash("sha256")
    .update(`inmobiliaria24:${password}`)
    .digest("hex");
}
