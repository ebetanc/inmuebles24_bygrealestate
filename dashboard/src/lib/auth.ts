import { createHash } from "crypto";

export const SESSION_COOKIE = "dashboard_session";

/** Default session duration in seconds: 8 hours (down from 30 days). */
const DEFAULT_MAX_AGE_SEC = 8 * 60 * 60; // 28800

export function getSessionMaxAge(): number {
  const env = process.env.SESSION_MAX_AGE_SECONDS;
  if (env) {
    const parsed = parseInt(env, 10);
    if (!isNaN(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return DEFAULT_MAX_AGE_SEC;
}

export function generateSessionToken(password: string): string {
  return createHash("sha256")
    .update(`inmobiliaria24:${password}`)
    .digest("hex");
}
