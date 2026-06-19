"use client";

import { useCallback, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Agent } from "@/lib/types";
import { setAgentAvailability } from "./actions";
import AgentFormModal from "./agent-form-modal";

const agentFills = [
  "var(--primary-fill)",
  "var(--accent-fill)",
  "var(--alert-fill)",
  "var(--neutral)",
  "var(--bg-3)",
  "var(--primary-fill)",
];

interface Props {
  agents: Agent[];
  aliases: Record<string, string[]>;
  stats: Record<string, number>;
}

export default function AgentManager({ agents, aliases, stats }: Props) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [modalAgent, setModalAgent] = useState<Agent | null | "new">(null);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const toggleAvailability = (agent: Agent) => {
    const next = !agent.is_available;
    if (!next && !confirm(`Desactivar a ${agent.name}? Saldra del calendario y del ruteo.`)) return;
    startTransition(async () => {
      const result = await setAgentAvailability(agent.agent_id, next);
      if (result.success) {
        showToast(next ? `${agent.name} reactivado` : `${agent.name} desactivado`);
        router.refresh();
      } else {
        showToast(`Error: ${result.error}`);
      }
    });
  };

  const activeCount = agents.filter((a) => a.is_available).length;

  return (
    <div>
      <div className="mb-5 flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Equipo de Agentes</h2>
          <div className="text-xs text-muted-foreground">
            {activeCount} activos de {agents.length} — administra el equipo
          </div>
        </div>
        <button
          onClick={() => setModalAgent("new")}
          className="inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-primary px-4 py-2 font-display text-xs font-bold text-primary-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-foreground hover:text-background hover:shadow-[var(--shadow-hover)]"
        >
          + Nuevo agente
        </button>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {agents.map((agent, i) => {
          const initials = agent.name
            .split(" ")
            .map((n) => n[0])
            .join("")
            .substring(0, 2)
            .toUpperCase();
          const fill = agentFills[i % agentFills.length];
          const agentAliases = aliases[agent.agent_id] || [];

          return (
            <div
              key={agent.agent_id}
              className={`nb nb-hover p-5 ${agent.is_available ? "" : "opacity-55"}`}
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
                {!agent.is_available ? (
                  <span className="nb-chip">Inactivo</span>
                ) : agent.on_shift ? (
                  <span className="nb-chip is-primary">
                    <span className="dot live" />
                    En turno
                  </span>
                ) : (
                  <span className="nb-chip">Fuera de turno</span>
                )}
              </div>

              {/* Stats grid */}
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--bg-3)] px-3 py-2.5">
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Leads Semana</div>
                  <div className="mt-0.5 font-mono text-lg font-bold text-foreground">{stats[agent.agent_id] || 0}</div>
                </div>
                <div className="rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--bg-3)] px-3 py-2.5">
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">WhatsApp</div>
                  <div className="mt-0.5 text-xs font-mono text-foreground truncate">{agent.whatsapp_number || "-"}</div>
                </div>
              </div>

              {/* Aliases */}
              {agentAliases.length > 0 && (
                <div className="mt-3 flex flex-wrap gap-1.5">
                  {agentAliases.map((tag) => (
                    <span key={tag} className="nb-chip text-[10px]">{tag}</span>
                  ))}
                </div>
              )}

              {/* Actions */}
              <div className="mt-4 flex items-center gap-2">
                <button
                  onClick={() => setModalAgent(agent)}
                  className="flex-1 px-3 py-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-card font-display text-xs font-bold text-foreground hover:bg-accent transition-colors"
                >
                  Editar
                </button>
                <button
                  onClick={() => toggleAvailability(agent)}
                  disabled={isPending}
                  className={`flex-1 px-3 py-1.5 rounded-[var(--radius-sm)] border-2 border-foreground font-display text-xs font-bold transition-colors disabled:opacity-40 ${
                    agent.is_available
                      ? "bg-destructive text-destructive-foreground hover:bg-foreground hover:text-background"
                      : "bg-primary text-primary-foreground hover:bg-foreground hover:text-background"
                  }`}
                >
                  {agent.is_available ? "Desactivar" : "Reactivar"}
                </button>
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

      {modalAgent !== null && (
        <AgentFormModal
          agent={modalAgent === "new" ? null : modalAgent}
          aliases={modalAgent === "new" ? [] : aliases[modalAgent.agent_id] || []}
          onClose={() => setModalAgent(null)}
          onToast={showToast}
        />
      )}

      {toast && (
        <div className="fixed bottom-6 right-6 border-2 border-foreground bg-foreground text-background px-4 py-2.5 rounded-[var(--radius-sm)] font-display text-sm font-bold shadow-[var(--shadow-lg)] animate-fade-in z-[210]">
          {toast}
        </div>
      )}
    </div>
  );
}
