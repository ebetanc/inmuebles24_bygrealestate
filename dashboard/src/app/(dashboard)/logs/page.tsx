import { getTokkoNotices } from "@/lib/queries";
import { formatMx, mxStartOfToday } from "@/lib/datetime";

export const dynamic = "force-dynamic";

// Since 2026-10-10 every lead arrives as a Tokko notice email (WF25 reads it about a minute later).
// What V3 did with it: created_new = lead nuevo; returning_* = la misma persona ya tenía lead abierto.
function resultOf(n: { parse_ok: boolean; disposition: string | null; opportunity_id: number | null }) {
  if (!n.parse_ok) return { label: "No se pudo leer", cls: "is-alert" };
  if (!n.disposition) return { label: "Sin lead", cls: "is-blue" };
  if (n.disposition === "created_new") return { label: `Lead #${n.opportunity_id}`, cls: "is-primary" };
  if (n.disposition.startsWith("returning")) return { label: `Repetido · #${n.opportunity_id}`, cls: "is-accent" };
  return { label: n.disposition, cls: "is-blue" };
}

const portalLabel: Record<string, string> = { inmuebles24: "Inmuebles24", jamesedition: "JamesEdition" };

function fmtTime(iso: string) {
  return formatMx(iso, { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
}

export default async function TokkoNoticesPage() {
  const notices = await getTokkoNotices();

  const todayStart = mxStartOfToday();
  const today = notices.filter((n) => new Date(n.received_at ?? n.created_at) >= todayStart);
  const newToday = today.filter((n) => n.disposition === "created_new").length;
  const last = notices[0];

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Avisos Tokko</h2>
          <div className="text-xs text-muted-foreground">
            Cada aviso de consulta que Tokko manda por correo y el lead que generó en V3 — últimos 100
          </div>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">{today.length}</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Avisos hoy</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">{newToday}</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Leads nuevos hoy</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[15px] font-bold text-background leading-tight pt-1">
            {last ? fmtTime(last.received_at ?? last.created_at) : "—"}
          </div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Último aviso</div>
        </div>
      </div>

      <div className="flex flex-col gap-2">
        {notices.map((n) => {
          const result = resultOf(n);
          return (
            <div
              key={n.gmail_message_id}
              className="flex flex-wrap items-center gap-4 rounded-[var(--radius)] border-2 border-foreground bg-card px-5 py-3.5 shadow-[var(--shadow-sm)]"
            >
              <div className="shrink-0 w-[130px]">
                <div className="font-mono text-[13px] font-bold text-foreground tabular-nums">
                  {fmtTime(n.received_at ?? n.created_at)}
                </div>
                <div className="text-[11px] text-muted-foreground mt-0.5">{n.kind || "—"}</div>
              </div>

              <div className="shrink-0 w-[120px]">
                <span className="nb-chip is-accent">{portalLabel[n.portal ?? ""] ?? n.portal ?? "—"}</span>
              </div>

              <div className="min-w-[160px] flex-1">
                <div className="text-[13px] font-bold text-foreground">{n.lead_name || "Sin nombre"}</div>
                <div className="font-mono text-[11px] text-muted-foreground">{n.phone || n.email || "—"}</div>
              </div>

              <div className="min-w-[160px] flex-1">
                <div className="font-mono text-[11px] text-muted-foreground">{n.eb_ref || "sin ID EB"}</div>
                <div className="truncate text-[13px] text-foreground">{n.property_title || "—"}</div>
              </div>

              <div className="shrink-0">
                <span className={`nb-chip ${result.cls}`}>{result.label}</span>
              </div>
            </div>
          );
        })}
      </div>

      {notices.length === 0 && (
        <div className="nb p-12 text-center font-display text-sm font-bold text-muted-foreground">
          Aún no hay avisos de Tokko registrados
        </div>
      )}
    </div>
  );
}
