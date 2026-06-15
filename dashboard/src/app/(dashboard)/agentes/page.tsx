import { getAgents, getAgentStats } from "@/lib/queries";

export const dynamic = "force-dynamic";

const agentFills = [
  "var(--primary-fill)",
  "var(--accent-fill)",
  "var(--alert-fill)",
  "var(--neutral)",
  "var(--bg-3)",
  "var(--primary-fill)",
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
        <h2 className="font-display text-base font-bold text-foreground">Equipo de Agentes</h2>
        <div className="text-xs text-muted-foreground">{agents.length} agentes — rendimiento en tiempo real</div>
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
          const fill = agentFills[i % agentFills.length];

          return (
            <div
              key={agent.agent_id}
              className="nb nb-hover p-5"
            >
              {/* Top: Avatar + Name + Badge */}
              <div className="flex items-center gap-3.5 mb-4">
                <div
                  className="flex h-11 w-11 shrink-0 items-center justify-center rounded-[var(--radius-sm)] border-2 border-foreground font-display text-base font-bold text-foreground shadow-[var(--shadow-sm)]"
                  style={{ background: fill }}
                >
                  {initials}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="font-display text-[15px] font-bold text-foreground">{agent.name}</div>
                  <div className="text-xs font-semibold text-muted-foreground">Asesor</div>
                </div>
                {agent.on_shift ? (
                  <span className="nb-chip is-primary">
                    <span className="dot live" />
                    En turno
                  </span>
                ) : (
                  <span className="nb-chip">
                    Fuera de turno
                  </span>
                )}
              </div>

              {/* Stats grid */}
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--bg-3)] px-3 py-2.5">
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Leads Semana</div>
                  <div className="mt-0.5 font-mono text-lg font-bold text-foreground">{stats?.leadsThisWeek || 0}</div>
                </div>
                <div className="rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--bg-3)] px-3 py-2.5">
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">WhatsApp</div>
                  <div className="mt-0.5 text-xs font-mono text-foreground truncate">{agent.whatsapp_number || "-"}</div>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {agents.length === 0 && (
        <div className="nb p-12 text-center font-display text-sm font-bold text-muted-foreground">
          No hay agentes registrados
        </div>
      )}
    </div>
  );
}
