"use server";

import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { generateSessionToken, getSessionMaxAge, SESSION_COOKIE } from "@/lib/auth";
import { checkRateLimit, recordFailedAttempt, resetRateLimit } from "@/lib/rate-limit";

export async function login(_prev: { error: string } | null, formData: FormData) {
  const headersList = await headers();

  // Rate-limit check
  const rateLimit = checkRateLimit(headersList);
  if (!rateLimit.allowed) {
    const mins = Math.ceil(rateLimit.retryAfterSec / 60);
    return {
      error: `Demasiados intentos. Intenta de nuevo en ${mins} minuto(s).`,
    };
  }

  const password = formData.get("password") as string;
  const expected = process.env.DASHBOARD_PASSWORD;

  if (!expected) {
    return { error: "DASHBOARD_PASSWORD no configurado en el servidor" };
  }

  if (!password || password !== expected) {
    const result = recordFailedAttempt(headersList);
    if (result.blocked) {
      const mins = Math.ceil(result.retryAfterSec / 60);
      return {
        error: `Demasiados intentos fallidos. Cuenta bloqueada por ${mins} minuto(s).`,
      };
    }
    return { error: "Contrasena incorrecta" };
  }

  // Successful login: clear any rate-limit state for this IP
  resetRateLimit(headersList);

  const token = generateSessionToken(password);
  const maxAge = getSessionMaxAge();
  const cookieStore = await cookies();

  cookieStore.set(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge,
    path: "/",
  });

  redirect("/");
}

export async function logout() {
  const cookieStore = await cookies();
  cookieStore.delete(SESSION_COOKIE);
  redirect("/login");
}
