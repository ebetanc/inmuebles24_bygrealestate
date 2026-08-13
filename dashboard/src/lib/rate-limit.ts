/**
 * In-memory rate limiter for login attempts.
 *
 * Tracks failures per IP key. Uses a sliding-window approach:
 * - After MAX_ATTEMPTS failures within WINDOW_MS, the IP is blocked for BLOCK_DURATION_MS.
 * - Block duration doubles on each subsequent block (exponential backoff), capped at MAX_BLOCK_MS.
 *
 * NOTE: This is process-local and resets on cold starts. For serverless
 * deployments (Vercel), consider migrating to a Redis-backed store or
 * Supabase table for durable rate limiting.
 */

const MAX_ATTEMPTS = 5;
const WINDOW_MS = 5 * 60 * 1000; // 5 minutes
const BASE_BLOCK_MS = 15 * 60 * 1000; // 15 minutes
const MAX_BLOCK_MS = 24 * 60 * 60 * 1000; // 24 hours

interface Entry {
  failures: number[]; // timestamps of failures within the window
  blockUntil: number; // epoch ms until which this IP is blocked
  blockCount: number; // how many times this IP has been blocked
}

const store = new Map<string, Entry>();

// Periodic cleanup: remove expired entries every 10 minutes
if (typeof setInterval !== "undefined") {
  setInterval(() => {
    const now = Date.now();
    for (const [key, entry] of store) {
      if (entry.blockUntil < now && entry.failures.every((t) => now - t > WINDOW_MS)) {
        store.delete(key);
      }
    }
  }, 10 * 60 * 1000);
}

function getClientIp(headers: Headers): string {
  // Vercel / reverse-proxy forwarding
  const forwarded = headers.get("x-forwarded-for");
  if (forwarded) {
    return forwarded.split(",")[0].trim();
  }
  return "unknown";
}

export function checkRateLimit(headers: Headers): { allowed: boolean; retryAfterSec: number } {
  const ip = getClientIp(headers);
  const now = Date.now();
  let entry = store.get(ip);

  if (!entry) {
    entry = { failures: [], blockUntil: 0, blockCount: 0 };
    store.set(ip, entry);
  }

  // Check if currently blocked
  if (entry.blockUntil > now) {
    const retryAfterSec = Math.ceil((entry.blockUntil - now) / 1000);
    return { allowed: false, retryAfterSec };
  }

  // Prune old failures outside the window
  entry.failures = entry.failures.filter((t) => now - t <= WINDOW_MS);

  return { allowed: true, retryAfterSec: 0 };
}

export function recordFailedAttempt(headers: Headers): { blocked: boolean; retryAfterSec: number } {
  const ip = getClientIp(headers);
  const now = Date.now();
  let entry = store.get(ip);

  if (!entry) {
    entry = { failures: [], blockUntil: 0, blockCount: 0 };
    store.set(ip, entry);
  }

  entry.failures.push(now);

  if (entry.failures.length >= MAX_ATTEMPTS) {
    const multiplier = Math.pow(2, entry.blockCount);
    const blockDuration = Math.min(BASE_BLOCK_MS * multiplier, MAX_BLOCK_MS);
    entry.blockUntil = now + blockDuration;
    entry.blockCount++;
    entry.failures = [];
    return { blocked: true, retryAfterSec: Math.ceil(blockDuration / 1000) };
  }

  return { blocked: false, retryAfterSec: 0 };
}

export function resetRateLimit(headers: Headers): void {
  const ip = getClientIp(headers);
  store.delete(ip);
}