"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { generateSessionToken, SESSION_COOKIE } from "@/lib/auth";

export async function login(_prev: { error: string } | null, formData: FormData) {
  const password = formData.get("password") as string;
  const expected = process.env.DASHBOARD_PASSWORD;

  if (!expected) {
    return { error: "DASHBOARD_PASSWORD no configurado en el servidor" };
  }

  if (!password || password !== expected) {
    return { error: "Contrasena incorrecta" };
  }

  const token = generateSessionToken(password);
  const cookieStore = await cookies();

  cookieStore.set(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: 60 * 60 * 24 * 30,
    path: "/",
  });

  redirect("/");
}

export async function logout() {
  const cookieStore = await cookies();
  cookieStore.delete(SESSION_COOKIE);
  redirect("/login");
}
