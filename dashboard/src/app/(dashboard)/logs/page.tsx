import { getScrapeRuns } from "@/lib/queries";

export const dynamic = "force-dynamic";

// Visual mapping per run status. "ok" = corrida limpia (con o sin leads).
const statusChip: Record<string, { label: string; cls: string; dot: string }> = {
  ok: { label: "OK", cls: "is-primary", dot: "bg-[var(--green)]" },
  running: { label: "En curso", cls: "is-accent", dot: "bg-[var(--accent)]" },
  dry_run: { label: "Prueba", cls: "is-blue", dot: "bg-[var(--blue)]" },
  auth_error: { label: "Error de sesión", cls: "is-alert", dot: "bg-[var(--rose)]" },
  error: { label: "Error", cls: "is-alert", dot: "bg-[var(--rose)]" },
};

function fmtTime(iso: string) {
  return new Date(iso).toLocaleString("es-MX", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function duration(started: string, completed: string | null) {
  if (!completed) return "—";
  const secs = Math.round((new Date(completed).getTime() - new Date(started).getTime()) / 1000);
  if (secs < 60) return `${secs}s`;
  return `${Math.floor(secs / 60)}m ${secs % 60}s`;
}

export default async function LogsPage() {
  const runs = await getScrapeRuns();

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const runsToday = runs.filter((r) => new Date(r.started_at) >= todayStart);
  const leadsToday = runsToday.reduce((sum, r) => sum + (r.new_listings || 0), 0);
  const lastRun = runs[0];

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Logs de Subastas</h2>
          <div className="text-xs text-muted-foreground">
            Bitácora del scraper (Pi) — una corrida cada 15 min, 08:00–22:00 MX
          </div>
        </div>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">{runsToday.length}</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Corridas hoy</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[32px] font-bold text-background">{leadsToday}</div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Leads nuevos hoy</div>
        </div>
        <div className="rounded-[var(--radius)] border-2 border-foreground bg-foreground p-5 shadow-[var(--shadow-sm)]">
          <div className="font-mono text-[15px] font-bold text-background leading-tight pt-1">
            {lastRun ? fmtTime(lastRun.started_at) : "—"}
          </div>
          <div className="font-display text-[11px] font-extrabold uppercase tracking-[0.06em] text-background/70 mt-1">Última corrida</div>
        </div>
      </div>

      {/* Run rows */}
      <div className="flex flex-col gap-2">
        {runs.map((run) => {
          const chip = statusChip[run.status] || { label: run.status, cls: "is-blue", dot: "bg-[var(--blue)]" };
          const noLeads = (run.new_listings || 0) === 0;

          return (
            <div
              key={run.id}
              className="flex items-center gap-4 rounded-[var(--radius)] border-2 border-foreground bg-card px-5 py-3.5 shadow-[var(--shadow-sm)]"
            >
              {/* Time */}
              <div className="shrink-0 w-[150px]">
                <div className="font-mono text-[13px] font-bold text-foreground tabular-nums">
                  {fmtTime(run.started_at)}
                </div>
                <div className="text-[11px] text-muted-foreground mt-0.5">
                  Duración {duration(run.started_at, run.completed_at)}
                </div>
              </div>

              {/* Status */}
              <div className="shrink-0 w-[130px]">
                <span className={`nb-chip ${chip.cls}`}>
                  <span className={`h-2 w-2 rounded-full ${chip.dot}`} />
                  {chip.label}
                </span>
              </div>

              {/* Counts */}
              <div className="flex flex-1 gap-6">
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Leads nuevos</div>
                  <div className={`mt-0.5 font-mono text-[14px] font-bold tabular-nums ${noLeads ? "text-muted-foreground" : "text-foreground"}`}>
                    {run.new_listings || 0}
                  </div>
                </div>
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Total scrapeados</div>
                  <div className="mt-0.5 font-mono text-[14px] font-bold text-foreground tabular-nums">
                    {run.total_scraped || 0}
                  </div>
                </div>
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Duplicados</div>
                  <div className="mt-0.5 font-mono text-[14px] font-bold text-muted-foreground tabular-nums">
                    {run.duplicates || 0}
                  </div>
                </div>
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Páginas</div>
                  <div className="mt-0.5 font-mono text-[14px] font-bold text-muted-foreground tabular-nums">
                    {run.pages_scraped || 0}
                  </div>
                </div>
              </div>

              {/* Error message, if any */}
              {run.error_message && (
                <div className="shrink-0 max-w-[260px] truncate text-[11px] font-semibold text-[var(--rose)]" title={run.error_message}>
                  {run.error_message}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {runs.length === 0 && (
        <div className="nb p-12 text-center font-display text-sm font-bold text-muted-foreground">
          Aún no hay corridas registradas — esperando la próxima ejecución del Pi
        </div>
      )}
    </div>
  );
}
