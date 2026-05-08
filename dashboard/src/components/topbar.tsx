"use client";

import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { AutoRefresh } from "./auto-refresh";

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
        now.toLocaleDateString("es-MX", { weekday: "short", day: "numeric", month: "short" }) +
          " — " +
          now.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit", second: "2-digit" })
      );
    };
    update();
    const interval = setInterval(update, 1000);
    return () => clearInterval(interval);
  }, []);

  const title = pageTitles[pathname] || "Dashboard";

  return (
    <header className="sticky top-0 z-50 flex h-16 items-center justify-between border-b border-[#E2E8F0] bg-white px-8">
      <div className="flex items-center gap-4">
        <span className="text-lg font-bold text-[#0F172A]">{title}</span>
        <div className="flex items-center gap-1.5 rounded-full border border-[#BBF7D0] bg-[#F0FDF4] px-3 py-1">
          <span className="h-2 w-2 rounded-full bg-[#22C55E] animate-pulse-live" />
          <span className="text-xs font-semibold text-[#16A34A]">En vivo</span>
        </div>
      </div>
      <div className="flex items-center gap-4">
        <AutoRefresh />
        <span className="text-[13px] font-medium text-[#64748B] tabular-nums">{clock}</span>
        <div className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-br from-[#3B82F6] to-[#8B5CF6] text-sm font-bold text-white cursor-pointer">
          EB
        </div>
      </div>
    </header>
  );
}
