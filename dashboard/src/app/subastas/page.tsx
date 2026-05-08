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
          <h2 className="text-base font-bold text-[#0F172A]">Subastas TOMO</h2>
          <div className="text-xs text-[#94A3B8]">Sistema de subasta — primer agente en responder gana el lead</div>
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
              className={`rounded-xl bg-white p-5 transition-shadow hover:shadow-md ${
                isExpired
                  ? "border border-[#E2E8F0]"
                  : "border-2 border-[#3B82F6] animate-pulse-border"
              }`}
            >
              {/* Top row */}
              <div className="flex items-center justify-between mb-3">
                <span className="font-mono text-[13px] font-bold text-[#3B82F6]">
                  {auction.short_code}
                </span>
                <span
                  className={`inline-flex items-center gap-[5px] rounded-full border px-2.5 py-0.5 text-[11.5px] font-semibold ${
                    isExpired
                      ? "border-[#FECACA] bg-[#FEF2F2] text-[#DC2626]"
                      : "border-[#BBF7D0] bg-[#F0FDF4] text-[#16A34A]"
                  }`}
                >
                  <span className={`h-1.5 w-1.5 rounded-full ${isExpired ? "bg-[#EF4444]" : "bg-[#22C55E]"}`} />
                  {isExpired ? "Expirado" : "Activa"}
                </span>
              </div>

              {/* Meta */}
              <div className="flex gap-6 mb-3">
                <div>
                  <div className="text-[10.5px] font-medium uppercase tracking-wide text-[#94A3B8]">Lead</div>
                  <div className="mt-0.5 text-[13px] font-semibold text-[#334155]">
                    {auction.lead_name || "Sin nombre"}
                  </div>
                </div>
                <div>
                  <div className="text-[10.5px] font-medium uppercase tracking-wide text-[#94A3B8]">Propiedad</div>
                  <div className="mt-0.5 text-[13px] font-semibold text-[#334155]">
                    {auction.property_title || auction.conversation_id}
                  </div>
                </div>
                <div>
                  <div className="text-[10.5px] font-medium uppercase tracking-wide text-[#94A3B8]">Tiempo</div>
                  <div className="mt-0.5 text-[13px] font-bold text-[#0F172A] tabular-nums">
                    {remaining}
                  </div>
                </div>
              </div>

              {/* Progress bar */}
              <div className="h-1 rounded-full bg-[#E2E8F0] overflow-hidden">
                <div
                  className="h-full rounded-full transition-all duration-700"
                  style={{
                    width: `${pct}%`,
                    background: isExpired
                      ? "linear-gradient(90deg, #EF4444, #F97316)"
                      : "linear-gradient(90deg, #3B82F6, #60A5FA)",
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>

      {auctions.length === 0 && (
        <div className="rounded-xl border border-[#E2E8F0] bg-white p-12 text-center text-sm text-[#94A3B8]">
          No hay subastas activas en este momento
        </div>
      )}
    </div>
  );
}
