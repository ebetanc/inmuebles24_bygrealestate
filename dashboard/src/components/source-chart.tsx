"use client";

interface SourceChartProps {
  bySource: {
    inmuebles24: number;
    easybroker: number;
    whatsapp_direct: number;
  };
}

const sources = [
  { key: "inmuebles24" as const, label: "Inmuebles24", color: "var(--blue)" },
  { key: "whatsapp_direct" as const, label: "WhatsApp", color: "var(--orchid)" },
  { key: "easybroker" as const, label: "EasyBroker", color: "var(--amber)" },
];

export function SourceChart({ bySource }: SourceChartProps) {
  const total = bySource.inmuebles24 + bySource.easybroker + bySource.whatsapp_direct;
  const circumference = 2 * Math.PI * 70; // r=70

  if (total === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-8">
        <svg className="w-[170px] h-[170px]" viewBox="0 0 200 200" style={{ transform: "rotate(-90deg)" }}>
          <circle cx="100" cy="100" r="70" fill="none" stroke="var(--bg-3)" strokeWidth={28} />
        </svg>
        <p className="mt-4 font-display text-sm font-bold text-muted-foreground">Sin datos esta semana</p>
      </div>
    );
  }

  const percentages = sources.map((s) => ({
    ...s,
    pct: Math.round((bySource[s.key] / total) * 100),
    raw: bySource[s.key] / total,
  }));

  let offset = 0;
  const segments = percentages.map((s) => {
    const dashArray = s.raw * circumference;
    const dashOffset = -offset;
    offset += dashArray;
    return { ...s, dashArray, dashOffset };
  });

  return (
    <div className="flex items-center justify-center gap-8 py-3">
      <svg className="w-[170px] h-[170px]" viewBox="0 0 200 200" style={{ transform: "rotate(-90deg)" }}>
        <circle cx="100" cy="100" r="70" fill="none" stroke="var(--bg-3)" strokeWidth={28} />
        {segments.map((s) => (
          <circle
            key={s.key}
            cx="100"
            cy="100"
            r="70"
            fill="none"
            stroke={s.color}
            strokeWidth={28}
            strokeLinecap="round"
            strokeDasharray={`${s.dashArray} ${circumference}`}
            strokeDashoffset={s.dashOffset}
          />
        ))}
      </svg>
      <div className="flex flex-col gap-3">
        {percentages.map((s) => (
          <div key={s.key} className="flex items-center gap-2.5 text-[13px]">
            <div className="h-3.5 w-3.5 rounded-[3px] border-2 border-foreground shrink-0" style={{ background: s.color }} />
            <span className="font-medium text-foreground">{s.label}</span>
            <span className="font-mono font-bold text-foreground min-w-[36px]">{s.pct}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}
