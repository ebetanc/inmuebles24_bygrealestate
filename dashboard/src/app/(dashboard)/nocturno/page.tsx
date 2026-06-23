import { getNightQueue } from "@/lib/queries";
import { formatMx } from "@/lib/datetime";

export const dynamic = "force-dynamic";

const tempFills: Record<string, string> = {
  high: "var(--alert-fill)",
  medium: "var(--accent-fill)",
  low: "var(--neutral)",
  unknown: "var(--bg-3)",
};

export default async function NocturnoPage() {
  const queue = await getNightQueue();

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Modo Nocturno</h2>
          <div className="text-xs text-muted-foreground">Leads fuera de horario — TOMO automatico a las 8:05 AM</div>
        </div>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">{queue.length}</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">En cola</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">
            {queue.filter((q) => q.temperature === "high").length}
          </div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Calientes</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">8:05</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Proximo TOMO</div>
        </div>
      </div>

      {/* Night queue cards */}
      <div className="flex flex-col gap-3">
        {queue.map((item) => {
          const fill = tempFills[item.temperature || "unknown"];
          const time = formatMx(item.queued_at, {
            hour: "2-digit",
            minute: "2-digit",
          });

          return (
            <div
              key={item.id}
              className="flex items-center gap-4 rounded-[var(--radius)] border-2 border-foreground bg-card px-5 py-4 shadow-[var(--shadow-sm)]"
            >
              {/* Temperature indicator */}
              <div
                className="h-10 w-3 shrink-0 rounded-[6px] border-2 border-foreground"
                style={{ background: fill }}
              />

              {/* Info */}
              <div className="flex-1 min-w-0">
                <div className="font-display text-sm font-bold text-foreground">
                  {item.lead_name || "Sin nombre"}
                </div>
                <div className="text-xs text-muted-foreground mt-0.5 truncate">
                  {item.property_id || "Sin propiedad"} — {item.source}
                </div>
                <div className="text-[11px] text-muted-foreground mt-1">
                  Recibido {time}
                </div>
              </div>

              {/* Phone */}
              <div className="text-right shrink-0 flex flex-col items-end gap-1">
                <div className="text-xs font-mono text-foreground">{item.lead_phone}</div>
                {item.temperature && (
                  <span
                    className={`nb-chip ${
                      item.temperature === "high"
                        ? "is-alert"
                        : item.temperature === "medium"
                        ? "is-accent"
                        : "is-blue"
                    }`}
                  >
                    {{ high: "Caliente", medium: "Tibio", low: "Frio" }[item.temperature] || item.temperature}
                  </span>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {queue.length === 0 && (
        <div className="nb p-12 text-center font-display text-sm font-bold text-muted-foreground">
          Cola nocturna vacia — todos los leads fueron procesados
        </div>
      )}
    </div>
  );
}
