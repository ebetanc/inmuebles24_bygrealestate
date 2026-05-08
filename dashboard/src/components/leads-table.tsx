import type { Conversation } from "@/lib/types";

interface LeadsTableProps {
  conversations: Conversation[];
}

const sourceStyles: Record<string, { bg: string; text: string; dot: string; label: string }> = {
  inmuebles24: { bg: "bg-[#EFF6FF]", text: "text-[#2563EB]", dot: "bg-[#3B82F6]", label: "Inmuebles24" },
  easybroker: { bg: "bg-[#FFFBEB]", text: "text-[#D97706]", dot: "bg-[#F59E0B]", label: "EasyBroker" },
  whatsapp_direct: { bg: "bg-[#F5F3FF]", text: "text-[#7C3AED]", dot: "bg-[#8B5CF6]", label: "WhatsApp" },
};

const modeStyles: Record<string, { bg: string; text: string; dot: string; label: string }> = {
  assigned: { bg: "bg-[#F0FDF4]", text: "text-[#16A34A]", dot: "bg-[#22C55E]", label: "Asignado" },
  pending_assignment: { bg: "bg-[#FFFBEB]", text: "text-[#D97706]", dot: "bg-[#F59E0B]", label: "En subasta" },
  ai: { bg: "bg-[#F5F3FF]", text: "text-[#7C3AED]", dot: "bg-[#8B5CF6]", label: "Bot AI" },
  night_queued: { bg: "bg-[#F8FAFC]", text: "text-[#64748B]", dot: "bg-[#94A3B8]", label: "Cola nocturna" },
  human: { bg: "bg-[#EFF6FF]", text: "text-[#2563EB]", dot: "bg-[#3B82F6]", label: "Humano" },
  expired: { bg: "bg-[#FEF2F2]", text: "text-[#DC2626]", dot: "bg-[#EF4444]", label: "Expirado" },
};

function Badge({ style }: { style: { bg: string; text: string; dot: string; label: string } }) {
  return (
    <span className={`inline-flex items-center gap-[5px] rounded-full border px-2.5 py-0.5 text-[11.5px] font-semibold whitespace-nowrap ${style.bg} ${style.text} border-current/20`}>
      <span className={`h-1.5 w-1.5 rounded-full shrink-0 ${style.dot}`} />
      {style.label}
    </span>
  );
}

export function LeadsTable({ conversations }: LeadsTableProps) {
  if (conversations.length === 0) {
    return (
      <div className="flex h-32 items-center justify-center text-sm text-[#94A3B8]">
        No hay leads recientes
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse">
        <thead>
          <tr>
            {["Hora", "Lead", "Propiedad", "Fuente", "Estado", "Agente"].map((h) => (
              <th
                key={h}
                className="border-b border-[#E2E8F0] bg-[#F8FAFC] px-3.5 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-[#64748B]"
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
              <tr key={c.conversation_id} className="transition-colors hover:bg-[#F8FAFC]">
                <td className="border-b border-[#F1F5F9] px-3.5 py-3 text-[13px] font-semibold text-[#334155] tabular-nums">
                  {time}
                </td>
                <td className="border-b border-[#F1F5F9] px-3.5 py-3">
                  <div className="text-[13px] font-bold text-[#0F172A]">{c.lead_name || "Sin nombre"}</div>
                  <div className="text-[11px] text-[#94A3B8]">{c.lead_phone}</div>
                </td>
                <td className="border-b border-[#F1F5F9] px-3.5 py-3 text-[13px] text-[#334155] max-w-[180px] truncate">
                  {c.current_property || "-"}
                </td>
                <td className="border-b border-[#F1F5F9] px-3.5 py-3">
                  <Badge style={source} />
                </td>
                <td className="border-b border-[#F1F5F9] px-3.5 py-3">
                  <Badge style={mode} />
                </td>
                <td className="border-b border-[#F1F5F9] px-3.5 py-3 text-[13px] font-bold text-[#334155]">
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
