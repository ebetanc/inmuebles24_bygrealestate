import { getNightQueue } from "@/lib/queries";

export const dynamic = "force-dynamic";

const tempGradients: Record<string, string> = {
  high: "linear-gradient(180deg, #EF4444, #F97316)",
  medium: "linear-gradient(180deg, #F59E0B, #FBBF24)",
  low: "linear-gradient(180deg, #3B82F6, #93C5FD)",
};

export default async function NocturnoPage() {
  const queue = await getNightQueue();

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="text-base font-bold text-[#0F172A]">Modo Nocturno</h2>
          <div className="text-xs text-[#94A3B8]">Leads fuera de horario — TOMO automatico a las 8:05 AM</div>
        </div>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="rounded-xl bg-gradient-to-br from-[#1E1B4B] to-[#312E81] border border-[#4338CA] p-5">
          <div className="text-[32px] font-extrabold text-[#E0E7FF]">{queue.length}</div>
          <div className="text-xs text-[#C7D2FE] mt-1">En cola</div>
        </div>
        <div className="rounded-xl bg-gradient-to-br from-[#1E1B4B] to-[#312E81] border border-[#4338CA] p-5">
          <div className="text-[32px] font-extrabold text-[#E0E7FF]">
            {queue.filter((q) => q.temperature === "high").length}
          </div>
          <div className="text-xs text-[#C7D2FE] mt-1">Calientes</div>
        </div>
        <div className="rounded-xl bg-gradient-to-br from-[#1E1B4B] to-[#312E81] border border-[#4338CA] p-5">
          <div className="text-[32px] font-extrabold text-[#E0E7FF]">8:05</div>
          <div className="text-xs text-[#C7D2FE] mt-1">Proximo TOMO</div>
        </div>
      </div>

      {/* Night queue cards */}
      <div className="flex flex-col gap-3">
        {queue.map((item) => {
          const gradient = tempGradients[item.temperature || "cold"] || tempGradients.cold;
          const time = new Date(item.created_at).toLocaleTimeString("es-MX", {
            hour: "2-digit",
            minute: "2-digit",
          });

          return (
            <div
              key={item.id}
              className="flex items-center gap-4 rounded-xl border border-[#E2E8F0] bg-white px-5 py-4"
            >
              {/* Temperature indicator */}
              <div
                className="h-10 w-2.5 shrink-0 rounded-full"
                style={{ background: gradient }}
              />

              {/* Info */}
              <div className="flex-1 min-w-0">
                <div className="text-sm font-bold text-[#0F172A]">
                  {item.lead_name || "Sin nombre"}
                </div>
                <div className="text-xs text-[#64748B] mt-0.5 truncate">
                  {item.property_id || "Sin propiedad"} — {item.source}
                </div>
                <div className="text-[11px] text-[#94A3B8] mt-1">
                  Recibido {time}
                </div>
              </div>

              {/* Phone */}
              <div className="text-right shrink-0">
                <div className="text-xs font-mono text-[#64748B]">{item.lead_phone}</div>
                {item.temperature && (
                  <span
                    className={`mt-1 inline-block rounded-full px-2 py-0.5 text-[10px] font-semibold ${
                      item.temperature === "high"
                        ? "bg-[#FEF2F2] text-[#DC2626]"
                        : item.temperature === "medium"
                        ? "bg-[#FFFBEB] text-[#D97706]"
                        : "bg-[#EFF6FF] text-[#2563EB]"
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
        <div className="rounded-xl border border-[#E2E8F0] bg-white p-12 text-center text-sm text-[#94A3B8]">
          Cola nocturna vacia — todos los leads fueron procesados
        </div>
      )}
    </div>
  );
}
