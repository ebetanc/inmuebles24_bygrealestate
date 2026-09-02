import { getV3Leads, getV3Kpis } from "@/lib/queries";
import { formatMx } from "@/lib/datetime";
import type { V3Lead } from "@/lib/types";

export const dynamic = "force-dynamic";

type PillStyle = { fill: string; dot: string; label: string };

const estadoPills: Record<string, PillStyle> = {
  asignado: { fill: "bg-[var(--primary-fill)]", dot: "bg-[var(--green)]", label: "Asignado" },
  oferta: { fill: "bg-[var(--accent-fill)]", dot: "bg-[var(--amber)]", label: "En oferta" },
  cola: { fill: "bg-[var(--bg-3)]", dot: "bg-[var(--tx-lo)]", label: "En cola" },
  revision: { fill: "bg-[var(--alert-fill)]", dot: "bg-[var(--rose)]", label: "En revision" },
};

function estadoOf(l: V3Lead): PillStyle {
  if (l.assigned_agent_id) return estadoPills.asignado;
  if (l.dispatch_status === "manual_review") return estadoPills.revision;
  if (l.night_queued_at && !l.night_released_at) return estadoPills.cola;
  return estadoPills.oferta;
}

function Pill({ pill }: { pill: PillStyle }) {
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground px-2.5 py-1 font-display text-[11px] font-extrabold uppercase tracking-[0.03em] text-foreground whitespace-nowrap ${pill.fill}`}>
      <span className={`h-2 w-2 rounded-full shrink-0 ${pill.dot}`} />
      {pill.label}
    </span>
  );
}

/** true = hecho, false = fallo, null = todavia no aplica. */
function Mark({ ok, label }: { ok: boolean | null; label: string }) {
  const glyph = ok === true ? "✔" : ok === false ? "✘" : "–";
  const color = ok === true ? "var(--green)" : ok === false ? "var(--rose)" : "var(--tx-lo)";
  return (
    <span className="mr-2.5 whitespace-nowrap text-[12px] text-muted-foreground">
      {label} <span className="font-bold" style={{ color }}>{glyph}</span>
    </span>
  );
}

function responsable(l: V3Lead): string {
  if (!l.assigned_agent_id) return "Sin responsable todavia";
  if (l.assignment_method === "claim") {
    return l.minutes_to_claim !== null
      ? `toco Tomo en ${l.minutes_to_claim} min`
      : "toco Tomo";
  }
  if (l.assignment_method === "sandy_fallback") return "Sandy por vencimiento";
  return "asignacion directa";
}

const kpiCards = [
  { key: "total" as const, label: "Leads Hoy" },
  { key: "claimed" as const, label: "Tomados" },
  { key: "sandy" as const, label: "A Sandy" },
  { key: "open" as const, label: "En Oferta" },
  { key: "withProblem" as const, label: "Con Problema" },
  { key: "avgMinutesToClaim" as const, label: "Prom. Tomo", suffix: " min" },
];

export default async function LeadsV3Page() {
  const [kpis, leads] = await Promise.all([getV3Kpis(), getV3Leads()]);

  return (
    <div>
      <div className="mb-5">
        <h2 className="font-display text-base font-bold text-foreground">Leads V3</h2>
        <div className="text-xs text-muted-foreground">
          Motor de ruteo V3 — ultimos 7 dias, leido de la vista v3_leads_dashboard
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6 mb-7">
        {kpiCards.map((card) => {
          const value = kpis[card.key];
          return (
            <div key={card.key} className="nb nb-hover p-5">
              <div className="mb-2 font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">
                {card.label}
              </div>
              <div className="font-mono text-[28px] font-bold leading-tight text-foreground">
                {value === null ? "--" : value}
                {card.suffix && value !== null && (
                  <span className="text-base font-medium text-muted-foreground">{card.suffix}</span>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {leads.length === 0 ? (
        <div className="flex h-32 items-center justify-center font-display text-sm font-bold text-muted-foreground">
          No hay leads V3 en los ultimos 7 dias
        </div>
      ) : (
        <div className="overflow-x-auto rounded-[var(--radius)] border-2 border-foreground bg-card shadow-[var(--shadow-sm)]">
          <table className="w-full border-collapse">
            <thead>
              <tr className="border-b-2 border-foreground bg-[var(--neutral)]">
                {["Hora", "Lead", "Propiedad", "Estado", "Responsable", "WhatsApp", "EasyBroker", "Problema"].map((h) => (
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
              {leads.map((l) => (
                <tr
                  key={l.opportunity_id}
                  className="border-b border-[var(--line-2)] transition-colors last:border-0 hover:bg-muted"
                >
                  <td className="px-3.5 py-3 font-mono text-[13px] font-semibold tabular-nums text-foreground">
                    {formatMx(l.created_at, { hour: "2-digit", minute: "2-digit" })}
                  </td>
                  <td className="px-3.5 py-3">
                    <div className="text-[13px] font-bold text-foreground">{l.lead_name || "Sin nombre"}</div>
                    <div className="font-mono text-[11px] text-muted-foreground">{l.lead_phone || "-"}</div>
                  </td>
                  <td className="max-w-[200px] px-3.5 py-3">
                    <div className="font-mono text-[11px] text-muted-foreground">{l.property_id || "sin ID EB"}</div>
                    {l.easybroker_url ? (
                      <a
                        href={l.easybroker_url}
                        target="_blank"
                        rel="noreferrer"
                        className="truncate text-[13px] font-bold text-foreground underline"
                      >
                        {l.property_title || "Ver en EasyBroker"}
                      </a>
                    ) : (
                      <div className="truncate text-[13px] text-foreground">{l.property_title || "-"}</div>
                    )}
                  </td>
                  <td className="px-3.5 py-3">
                    <Pill pill={estadoOf(l)} />
                  </td>
                  <td className="px-3.5 py-3">
                    <div className="text-[13px] font-bold text-foreground">{l.assigned_name || "-"}</div>
                    <div className="text-[11px] text-muted-foreground">{responsable(l)}</div>
                  </td>
                  <td className="px-3.5 py-3">
                    <Mark label="propietario" ok={l.owner_offer_delivered_at ? true : null} />
                    <Mark label="guardia" ok={l.guard_offer_delivered_at ? true : null} />
                  </td>
                  <td className="px-3.5 py-3">
                    <Mark label="nota" ok={l.eb_note_ok} />
                    <Mark label="Atendida" ok={l.eb_attended_ok} />
                  </td>
                  <td className="max-w-[220px] px-3.5 py-3 text-[12px] font-semibold text-[var(--rose)]">
                    {l.problem_reason || ""}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
