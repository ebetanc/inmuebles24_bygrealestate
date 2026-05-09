"use client";

import { useActionState } from "react";
import { login } from "./actions";

export default function LoginPage() {
  const [state, formAction, pending] = useActionState(login, null);

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#F8FAFC]">
      <div className="w-full max-w-sm">
        <div className="rounded-2xl border border-[#E2E8F0] bg-white p-8 shadow-sm">
          <div className="mb-6 text-center">
            <div className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-xl bg-gradient-to-br from-[#3B82F6] to-[#8B5CF6]">
              <span className="text-lg font-bold text-white">B</span>
            </div>
            <h1 className="text-lg font-bold text-[#0F172A]">BYG Real Estate</h1>
            <p className="mt-1 text-xs text-[#94A3B8]">Dashboard de monitoreo</p>
          </div>

          <form action={formAction}>
            <label
              htmlFor="password"
              className="mb-1.5 block text-xs font-medium text-[#475569]"
            >
              Contrasena
            </label>
            <input
              id="password"
              name="password"
              type="password"
              required
              autoFocus
              className="mb-4 w-full rounded-lg border border-[#E2E8F0] bg-[#F8FAFC] px-3 py-2.5 text-sm text-[#0F172A] outline-none focus:border-[#3B82F6] focus:ring-2 focus:ring-[#3B82F6]/20"
              placeholder="Ingresa la contrasena"
            />

            {state?.error && (
              <div className="mb-4 rounded-lg bg-[#FEF2F2] px-3 py-2 text-xs font-medium text-[#DC2626]">
                {state.error}
              </div>
            )}

            <button
              type="submit"
              disabled={pending}
              className="w-full rounded-lg bg-gradient-to-r from-[#3B82F6] to-[#6366F1] px-4 py-2.5 text-sm font-semibold text-white transition hover:opacity-90 disabled:opacity-50"
            >
              {pending ? "Verificando..." : "Entrar"}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
