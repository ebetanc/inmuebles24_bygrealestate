import type { KPIs } from "@/lib/types";

interface KPICardsProps {
  kpis: KPIs;
}

const kpiConfig = [
  {
    key: "totalLeadsToday" as const,
    label: "Leads Hoy",
    iconBg: "var(--neutral)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z" />
      </svg>
    ),
    format: (v: number) => String(v),
  },
  {
    key: "totalLeadsWeek" as const,
    label: "Leads Esta Semana",
    iconBg: "var(--primary-fill)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 18 9 11.25l4.306 4.306a11.95 11.95 0 0 1 5.814-5.518l2.74-1.22m0 0-5.94-2.281m5.94 2.28-2.28 5.941" />
      </svg>
    ),
    format: (v: number) => String(v),
  },
  {
    key: "avgResponseMin" as const,
    label: "Tiempo Prom. Respuesta",
    iconBg: "var(--accent-fill)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
      </svg>
    ),
    format: (v: number) => v > 0 ? String(v) : "--",
    suffix: " min",
  },
  {
    key: "conversionRate" as const,
    label: "Tasa de Asignacion",
    iconBg: "var(--primary-fill)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
      </svg>
    ),
    format: (v: number) => v > 0 ? String(v) : "--",
    suffix: "%",
  },
  {
    key: "nightQueuePending" as const,
    label: "Leads Nocturnos",
    iconBg: "var(--neutral)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M21.752 15.002A9.72 9.72 0 0 1 18 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 0 0 3 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 0 0 9.002-5.998Z" />
      </svg>
    ),
    format: (v: number) => String(v),
  },
  {
    key: "activeAuctions" as const,
    label: "Subastas Activas",
    iconBg: "var(--alert-fill)",
    iconColor: "var(--dark)",
    icon: (
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4">
        <path strokeLinecap="round" strokeLinejoin="round" d="M15.362 5.214A8.252 8.252 0 0 1 12 21 8.25 8.25 0 0 1 6.038 7.047 8.287 8.287 0 0 0 9 9.601a8.983 8.983 0 0 1 3.361-6.867 8.21 8.21 0 0 0 3 2.48Z" />
      </svg>
    ),
    format: (v: number) => String(v),
  },
];

export function KPICards({ kpis }: KPICardsProps) {
  return (
    <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6 mb-7">
      {kpiConfig.map((item) => {
        const value = kpis[item.key];
        return (
          <div
            key={item.key}
            className="nb nb-hover p-5"
          >
            <div className="flex items-center justify-between mb-2">
              <span className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">{item.label}</span>
              <div
                className="flex h-8 w-8 items-center justify-center rounded-[var(--radius-sm)] border-2 border-foreground"
                style={{ background: item.iconBg, color: item.iconColor }}
              >
                {item.icon}
              </div>
            </div>
            <div className="font-mono text-[28px] font-bold text-foreground leading-tight">
              {item.format(value)}
              {item.suffix && (
                <span className="text-base font-medium text-muted-foreground">{item.suffix}</span>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
