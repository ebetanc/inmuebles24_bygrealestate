"use client";

import { useActionState } from "react";
import { login } from "./actions";

export default function LoginPage() {
  const [state, formAction, pending] = useActionState(login, null);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background">
      <div className="app-bg" />
      <div className="w-full max-w-sm">
        <div className="rounded-[var(--radius-lg)] border-2 border-foreground bg-card p-8 shadow-[var(--shadow-lg)]">
          <div className="mb-6 text-center">
            <div className="brand-mark mx-auto mb-3 h-12 w-12 text-2xl">B</div>
            <h1 className="font-display text-lg font-bold text-foreground">BYG Real Estate</h1>
            <p className="mt-1 text-xs font-semibold text-muted-foreground">Dashboard de monitoreo</p>
          </div>

          <form action={formAction}>
            <label
              htmlFor="password"
              className="mb-1.5 block font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-foreground"
            >
              Contrasena
            </label>
            <input
              id="password"
              name="password"
              type="password"
              required
              autoFocus
              className="mb-4 w-full rounded-[var(--radius-sm)] border-2 border-foreground bg-card px-3 py-2.5 text-sm text-foreground outline-none transition-[box-shadow,transform] focus:-translate-x-px focus:-translate-y-px focus:shadow-[var(--shadow-sm)]"
              placeholder="Ingresa la contrasena"
            />

            {state?.error && (
              <div className="mb-4 rounded-[var(--radius-sm)] border-2 border-foreground bg-destructive px-3 py-2 text-xs font-bold text-destructive-foreground">
                {state.error}
              </div>
            )}

            <button
              type="submit"
              disabled={pending}
              className="w-full rounded-[var(--radius-sm)] border-2 border-foreground bg-primary px-4 py-2.5 font-display text-sm font-bold text-primary-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background,color] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-foreground hover:text-background hover:shadow-[var(--shadow-hover)] active:translate-x-0 active:translate-y-0 active:shadow-[var(--shadow-sm)] disabled:pointer-events-none disabled:opacity-50 disabled:shadow-none"
            >
              {pending ? "Verificando..." : "Entrar"}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
