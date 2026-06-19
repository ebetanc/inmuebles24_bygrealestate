"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createAgent, updateAgent, type AgentInput } from "./actions";
import type { Agent } from "@/lib/types";

interface Props {
  agent: Agent | null; // null = create
  aliases: string[];
  onClose: () => void;
  onToast: (msg: string) => void;
}

const inputClass =
  "w-full px-3 py-2 rounded-[var(--radius-sm)] text-sm font-semibold border-2 border-foreground bg-card text-foreground focus:outline-none focus:-translate-x-px focus:-translate-y-px focus:shadow-[var(--shadow-sm)] transition-[transform,box-shadow]";
const labelClass =
  "font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground";

export default function AgentFormModal({ agent, aliases, onClose, onToast }: Props) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const isEdit = agent !== null;

  const [name, setName] = useState(agent?.name ?? "");
  const [whatsapp, setWhatsapp] = useState(agent?.whatsapp_number ?? "");
  const [email, setEmail] = useState(agent?.easybroker_email ?? "");
  const [shiftSlot, setShiftSlot] = useState<string>(agent?.shift_slot ?? "");
  const [aliasText, setAliasText] = useState(aliases.join(", "));
  const [error, setError] = useState<string | null>(null);

  const handleSave = () => {
    setError(null);
    const input: AgentInput = {
      name,
      whatsapp_number: whatsapp,
      easybroker_email: email || null,
      shift_slot: shiftSlot === "" ? null : (shiftSlot as "morning" | "afternoon"),
      aliases: aliasText
        .split(",")
        .map((t) => t.trim())
        .filter(Boolean),
    };

    startTransition(async () => {
      const result = isEdit
        ? await updateAgent(agent!.agent_id, input)
        : await createAgent(input);

      if (result.success) {
        const warn = result.warnings?.length ? ` (${result.warnings.join("; ")})` : "";
        onToast(`${isEdit ? "Agente actualizado" : "Agente creado"}${warn}`);
        router.refresh();
        onClose();
      } else {
        setError(result.error);
      }
    });
  };

  return (
    <div
      className="fixed inset-0 z-[200] flex items-center justify-center bg-foreground/40 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-[var(--radius)] border-2 border-foreground bg-card shadow-[var(--shadow-lg)] max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b-2 border-foreground px-5 py-4">
          <h3 className="font-display text-sm font-bold text-foreground">
            {isEdit ? `Editar — ${agent!.name}` : "Nuevo agente"}
          </h3>
          <button
            onClick={onClose}
            className="font-display text-lg font-bold text-muted-foreground hover:text-foreground"
            aria-label="Cerrar"
          >
            ×
          </button>
        </div>

        {/* Body */}
        <div className="flex flex-col gap-4 px-5 py-5">
          {isEdit && (
            <div className="text-[11px] font-mono text-muted-foreground">
              ID: {agent!.agent_id}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <label className={labelClass}>Nombre *</label>
            <input className={inputClass} value={name} onChange={(e) => setName(e.target.value)} placeholder="Lupita" />
          </div>

          <div className="flex flex-col gap-1.5">
            <label className={labelClass}>WhatsApp *</label>
            <input
              className={`${inputClass} font-mono`}
              value={whatsapp}
              onChange={(e) => setWhatsapp(e.target.value)}
              placeholder="5554132332"
            />
            <span className="text-[10px] text-muted-foreground">10 digitos del numero (se guarda como 521…)</span>
          </div>

          <div className="flex flex-col gap-1.5">
            <label className={labelClass}>Email EasyBroker</label>
            <input
              className={inputClass}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="opcional"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <label className={labelClass}>Turno preferido</label>
            <select className={`${inputClass} cursor-pointer`} value={shiftSlot} onChange={(e) => setShiftSlot(e.target.value)}>
              <option value="">Ninguno</option>
              <option value="morning">Manana</option>
              <option value="afternoon">Tarde</option>
            </select>
          </div>

          <div className="flex flex-col gap-1.5">
            <label className={labelClass}>Aliases de propiedad</label>
            <input
              className={inputClass}
              value={aliasText}
              onChange={(e) => setAliasText(e.target.value)}
              placeholder="lupita, glozoya"
            />
            <span className="text-[10px] text-muted-foreground">
              Tags de EasyBroker separados por coma — para ruteo por propietario
            </span>
          </div>

          {error && (
            <div className="rounded-[var(--radius-sm)] border-2 border-foreground bg-destructive px-3 py-2 text-xs font-bold text-foreground">
              {error}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 border-t-2 border-foreground px-5 py-4">
          <button
            onClick={onClose}
            className="px-4 py-2 rounded-[var(--radius-sm)] border-2 border-foreground bg-card font-display text-xs font-bold text-foreground hover:bg-accent transition-colors"
          >
            Cancelar
          </button>
          <button
            onClick={handleSave}
            disabled={isPending}
            className="px-4 py-2 rounded-[var(--radius-sm)] border-2 border-foreground bg-primary font-display text-xs font-bold text-primary-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-foreground hover:text-background hover:shadow-[var(--shadow-hover)] disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {isPending ? "Guardando..." : isEdit ? "Guardar" : "Crear"}
          </button>
        </div>
      </div>
    </div>
  );
}
