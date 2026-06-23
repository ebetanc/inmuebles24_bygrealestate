"use client";

import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { AutoRefresh } from "./auto-refresh";
import { logout } from "@/app/login/actions";
import { MX_TZ } from "@/lib/datetime";

const pageTitles: Record<string, string> = {
  "/": "Vista General",
  "/leads": "Leads en Vivo",
  "/agentes": "Equipo de Agentes",
  "/subastas": "Subastas TOMO",
  "/nocturno": "Modo Nocturno",
  "/calendario": "Calendario de Guardias",
};

export function Topbar() {
  const pathname = usePathname();
  const [clock, setClock] = useState("");

  useEffect(() => {
    const update = () => {
      const now = new Date();
      setClock(
        now.toLocaleDateString("es-MX", { timeZone: MX_TZ, weekday: "short", day: "numeric", month: "short" }) +
          " — " +
          now.toLocaleTimeString("es-MX", { timeZone: MX_TZ, hour: "2-digit", minute: "2-digit", second: "2-digit" })
      );
    };
    update();
    const interval = setInterval(update, 1000);
    return () => clearInterval(interval);
  }, []);

  const title = pageTitles[pathname] || "Dashboard";

  return (
    <header className="sticky top-0 z-50 flex h-16 items-center justify-between border-b-2 border-foreground bg-card px-8">
      <div className="flex items-center gap-4">
        <span className="font-display text-lg font-bold text-foreground">{title}</span>
        <div className="nb-chip is-primary">
          <span className="dot live" />
          En vivo
        </div>
      </div>
      <div className="flex items-center gap-4">
        <AutoRefresh />
        <span className="font-mono text-[13px] font-medium text-muted-foreground tabular-nums">{clock}</span>
        <form action={logout}>
          <button
            type="submit"
            className="flex h-9 items-center gap-2 rounded-[var(--radius-sm)] border-2 border-foreground bg-card px-3 font-display text-xs font-bold text-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-accent hover:shadow-[var(--shadow-hover)]"
          >
            Salir
          </button>
        </form>
        <div className="brand-mark">BYG</div>
      </div>
    </header>
  );
}
