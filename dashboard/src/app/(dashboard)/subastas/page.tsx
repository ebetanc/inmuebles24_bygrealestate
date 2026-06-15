import { getActiveAuctions } from "@/lib/queries";

export const dynamic = "force-dynamic";

function timeLeft(expiresAt: string) {
  const diff = new Date(expiresAt).getTime() - Date.now();
  if (diff <= 0) return "Expirado";
  const mins = Math.floor(diff / 60000);
  const secs = Math.floor((diff % 60000) / 1000);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

function progressPct(createdAt: string, expiresAt: string) {
  const total = new Date(expiresAt).getTime() - new Date(createdAt).getTime();
  const elapsed = Date.now() - new Date(createdAt).getTime();
  return Math.min(100, Math.max(0, (elapsed / total) * 100));
}

export default async function SubastasPage() {
  const auctions = await getActiveAuctions();

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Subastas TOMO</h2>
          <div className="text-xs text-muted-foreground">Sistema de subasta — primer agente en responder gana el lead</div>
        </div>
      </div>

      <div className="space-y-3.5">
        {auctions.map((auction) => {
          const pct = progressPct(auction.created_at, auction.expires_at);
          const remaining = timeLeft(auction.expires_at);
          const isExpired = remaining === "Expirado";

          return (
            <div
              key={auction.auction_id}
              className={`rounded-[var(--radius)] border-2 border-foreground bg-card p-5 shadow-[var(--shadow-sm)] ${
                isExpired ? "" : "animate-pulse-border"
              }`}
            >
              {/* Top row */}
              <div className="flex items-center justify-between mb-3">
                <span className="inline-flex items-center rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--neutral)] px-2.5 py-1 font-mono text-[13px] font-bold text-foreground">
                  {auction.short_code}
                </span>
                <span className={`nb-chip ${isExpired ? "is-alert" : "is-primary"}`}>
                  <span className={`h-2 w-2 rounded-full ${isExpired ? "bg-[var(--rose)]" : "bg-[var(--green)]"}`} />
                  {isExpired ? "Expirado" : "Activa"}
                </span>
              </div>

              {/* Meta */}
              <div className="flex gap-6 mb-3">
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Lead</div>
                  <div className="mt-0.5 text-[13px] font-semibold text-foreground">
                    {auction.lead_name || "Sin nombre"}
                  </div>
                </div>
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Propiedad</div>
                  <div className="mt-0.5 text-[13px] font-semibold text-foreground">
                    {auction.property_title || auction.conversation_id}
                  </div>
                </div>
                <div>
                  <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Tiempo</div>
                  <div className="mt-0.5 font-mono text-[13px] font-bold text-foreground tabular-nums">
                    {remaining}
                  </div>
                </div>
              </div>

              {/* Progress bar */}
              <div className="h-3 rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--bg-3)] overflow-hidden">
                <div
                  className="h-full transition-all duration-700"
                  style={{
                    width: `${pct}%`,
                    background: isExpired ? "var(--alert-fill)" : "var(--primary-fill)",
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>

      {auctions.length === 0 && (
        <div className="nb p-12 text-center font-display text-sm font-bold text-muted-foreground">
          No hay subastas activas en este momento
        </div>
      )}
    </div>
  );
}
