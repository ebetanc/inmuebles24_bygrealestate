import type { Conversation } from "@/lib/types";

interface LeadsTableProps {
  conversations: Conversation[];
}

type ChipStyle = { fill: string; dot: string; label: string };

const sourceStyles: Record<string, ChipStyle> = {
  inmuebles24: { fill: "bg-[var(--neutral)]", dot: "bg-[var(--blue)]", label: "Inmuebles24" },
  easybroker: { fill: "bg-[var(--accent-fill)]", dot: "bg-[var(--amber)]", label: "EasyBroker" },
  whatsapp_direct: { fill: "bg-[var(--primary-fill)]", dot: "bg-[var(--orchid)]", label: "WhatsApp" },
};

const modeStyles: Record<string, ChipStyle> = {
  assigned: { fill: "bg-[var(--primary-fill)]", dot: "bg-[var(--green)]", label: "Asignado" },
  pending_assignment: { fill: "bg-[var(--accent-fill)]", dot: "bg-[var(--amber)]", label: "En subasta" },
  ai: { fill: "bg-[var(--neutral)]", dot: "bg-[var(--orchid)]", label: "Bot AI" },
  night_queued: { fill: "bg-[var(--bg-3)]", dot: "bg-[var(--tx-lo)]", label: "Cola nocturna" },
  human: { fill: "bg-[var(--neutral)]", dot: "bg-[var(--blue)]", label: "Humano" },
  expired: { fill: "bg-[var(--alert-fill)]", dot: "bg-[var(--rose)]", label: "Expirado" },
};

function Chip({ style }: { style: ChipStyle }) {
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground px-2.5 py-1 font-display text-[11px] font-extrabold uppercase tracking-[0.03em] text-foreground whitespace-nowrap ${style.fill}`}>
      <span className={`h-2 w-2 rounded-full shrink-0 ${style.dot}`} />
      {style.label}
    </span>
  );
}

export function LeadsTable({ conversations }: LeadsTableProps) {
  if (conversations.length === 0) {
    return (
      <div className="flex h-32 items-center justify-center font-display text-sm font-bold text-muted-foreground">
        No hay leads recientes
      </div>
    );
  }

  return (
    <div className="overflow-x-auto rounded-[var(--radius)] border-2 border-foreground shadow-[var(--shadow-sm)] bg-card">
      <table className="w-full border-collapse">
        <thead>
          <tr className="bg-[var(--neutral)] border-b-2 border-foreground">
            {["Hora", "Lead", "Propiedad", "Fuente", "Estado", "Agente"].map((h) => (
              <th
                key={h}
                className="px-3.5 py-3 text-left font-display text-[11px] font-extrabold uppercase tracking-[0.08em] text-foreground"
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {conversations.map((c) => {
            const time = new Date(c.created_at).toLocaleTimeString("es-MX", {
              hour: "2-digit",
              minute: "2-digit",
            });
            const source = sourceStyles[c.source] || sourceStyles.inmuebles24;
            const mode = modeStyles[c.mode] || modeStyles.assigned;

            return (
              <tr key={c.conversation_id} className="border-b border-[var(--line-2)] transition-colors hover:bg-muted last:border-0">
                <td className="px-3.5 py-3 font-mono text-[13px] font-semibold text-foreground tabular-nums">
                  {time}
                </td>
                <td className="px-3.5 py-3">
                  <div className="text-[13px] font-bold text-foreground">{c.lead_name || "Sin nombre"}</div>
                  <div className="font-mono text-[11px] text-muted-foreground">{c.lead_phone}</div>
                </td>
                <td className="px-3.5 py-3 text-[13px] text-foreground max-w-[180px] truncate">
                  {c.current_property || "-"}
                </td>
                <td className="px-3.5 py-3">
                  <Chip style={source} />
                </td>
                <td className="px-3.5 py-3">
                  <Chip style={mode} />
                </td>
                <td className="px-3.5 py-3 text-[13px] font-bold text-foreground">
                  {c.agent_name || "-"}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
