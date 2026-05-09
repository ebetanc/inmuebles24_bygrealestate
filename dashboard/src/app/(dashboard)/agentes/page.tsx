import { getAgents, getAgentStats } from "@/lib/queries";

export const dynamic = "force-dynamic";

const agentGradients = [
  "linear-gradient(135deg, #3B82F6, #2563EB)",
  "linear-gradient(135deg, #8B5CF6, #7C3AED)",
  "linear-gradient(135deg, #F59E0B, #D97706)",
  "linear-gradient(135deg, #EC4899, #DB2777)",
  "linear-gradient(135deg, #22C55E, #16A34A)",
  "linear-gradient(135deg, #06B6D4, #0891B2)",
];

export default async function AgentesPage() {
  const agents = await getAgents();
  const statsMap = new Map<string, { leadsThisWeek: number }>();

  await Promise.all(
    agents.map(async (a) => {
      const stats = await getAgentStats(a.agent_id);
      statsMap.set(a.agent_id, stats);
    })
  );

  return (
    <div>
      <div className="mb-5">
        <h2 className="text-base font-bold text-[#0F172A]">Equipo de Agentes</h2>
        <div className="text-xs text-[#94A3B8]">{agents.length} agentes — rendimiento en tiempo real</div>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {agents.map((agent, i) => {
          const stats = statsMap.get(agent.agent_id);
          const initials = agent.name
            .split(" ")
            .map((n) => n[0])
            .join("")
            .substring(0, 2)
            .toUpperCase();
          const gradient = agentGradients[i % agentGradients.length];

          return (
            <div
              key={agent.agent_id}
              className="rounded-xl border border-[#E2E8F0] bg-white p-5 transition-all hover:shadow-md hover:-translate-y-px"
            >
              {/* Top: Avatar + Name + Badge */}
              <div className="flex items-center gap-3.5 mb-4">
                <div
                  className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-base font-bold text-white"
                  style={{ background: gradient }}
                >
                  {initials}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="text-[15px] font-bold text-[#0F172A]">{agent.name}</div>
                  <div className="text-xs text-[#64748B]">Asesor</div>
                </div>
                {agent.on_shift ? (
                  <span className="inline-flex items-center gap-[5px] rounded-full border border-[#BBF7D0] bg-[#F0FDF4] px-2.5 py-0.5 text-[11.5px] font-semibold text-[#16A34A]">
                    <span className="h-1.5 w-1.5 rounded-full bg-[#22C55E]" />
                    En turno
                  </span>
                ) : (
                  <span className="inline-flex items-center gap-[5px] rounded-full border border-[#E2E8F0] bg-[#F8FAFC] px-2.5 py-0.5 text-[11.5px] font-semibold text-[#64748B]">
                    Fuera de turno
                  </span>
                )}
              </div>

              {/* Stats grid */}
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-lg bg-[#F8FAFC] px-3 py-2.5">
                  <div className="text-[10.5px] font-medium uppercase tracking-wide text-[#94A3B8]">Leads Semana</div>
                  <div className="mt-0.5 text-lg font-extrabold text-[#0F172A]">{stats?.leadsThisWeek || 0}</div>
                </div>
                <div className="rounded-lg bg-[#F8FAFC] px-3 py-2.5">
                  <div className="text-[10.5px] font-medium uppercase tracking-wide text-[#94A3B8]">WhatsApp</div>
                  <div className="mt-0.5 text-xs font-mono text-[#64748B] truncate">{agent.whatsapp_number || "-"}</div>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {agents.length === 0 && (
        <div className="rounded-xl border border-[#E2E8F0] bg-white p-12 text-center text-sm text-[#94A3B8]">
          No hay agentes registrados
        </div>
      )}
    </div>
  );
}
