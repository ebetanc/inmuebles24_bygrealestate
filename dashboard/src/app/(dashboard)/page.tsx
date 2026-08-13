import { KPICards } from "@/components/kpi-cards";
import { SourceChart } from "@/components/source-chart";
import { LeadsTable } from "@/components/leads-table";
import { getKPIs, getRecentConversations, getRoutingV2Ops, getRoutingV2KPIs } from "@/lib/queries";

export const dynamic = "force-dynamic";

function formatSla(seconds: number | null): string {
  if (seconds === null) return "—";
  const clamped = Math.max(0, seconds);
  const m = Math.floor(clamped / 60);
  const s = clamped % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export default async function DashboardPage() {
  const [kpis, recentLeads, routingV2Ops, routingV2Kpis] = await Promise.all([
    getKPIs(),
    getRecentConversations(10),
    getRoutingV2Ops(),
    getRoutingV2KPIs(7),
  ]);
  const unassigned = routingV2Ops.filter((o) => o.is_unassigned);

  return (
    <div>
      <KPICards kpis={kpis} />

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
        {/* Donut chart */}
        <div className="nb overflow-hidden">
          <div className="flex items-center justify-between border-b-2 border-foreground px-5 py-4">
            <div>
              <div className="font-display text-[15px] font-bold text-foreground">Leads por Fuente</div>
              <div className="text-xs text-muted-foreground">Distribucion ultimos 7 dias</div>
            </div>
          </div>
          <div className="p-5">
            <SourceChart bySource={kpis.bySource} />
          </div>
        </div>

        {/* Recent leads */}
        <div className="nb overflow-hidden">
          <div className="flex items-center justify-between border-b-2 border-foreground px-5 py-4">
            <div>
              <div className="font-display text-[15px] font-bold text-foreground">Leads Recientes</div>
              <div className="text-xs text-muted-foreground">Ultimos 10 leads recibidos</div>
            </div>
          </div>
          <div className="p-0">
            <LeadsTable conversations={recentLeads} />
          </div>
        </div>
      </div>

      {/* LRV2-014: routing-v2 pilot observability, derived entirely from DB */}
      <div className="nb mt-5 overflow-hidden">
        <div className="flex items-center justify-between border-b-2 border-foreground px-5 py-4">
          <div>
            <div className="font-display text-[15px] font-bold text-foreground">Lead Routing v2 (piloto)</div>
            <div className="text-xs text-muted-foreground">
              Ultimos {routingV2Kpis.days} dias &middot; {routingV2Kpis.escalations} escalamientos &middot;{" "}
              {routingV2Kpis.late_claims} claims tardios
            </div>
          </div>
        </div>
        <div className="p-5">
          {routingV2Ops.length === 0 ? (
            <div className="text-sm text-muted-foreground">Sin oportunidades activas en este momento.</div>
          ) : (
            <table className="mb-6 w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  <th className="pb-2">Oportunidad</th>
                  <th className="pb-2">Tier</th>
                  <th className="pb-2">Responsable</th>
                  <th className="pb-2">SLA restante</th>
                  <th className="pb-2">Ultima evidencia</th>
                </tr>
              </thead>
              <tbody>
                {routingV2Ops.map((o) => (
                  <tr key={o.opportunity_id} className="border-t border-foreground/10">
                    <td className="py-2 font-semibold">#{o.opportunity_id}</td>
                    <td className="py-2">{o.routing_tier || "—"}</td>
                    <td className="py-2">{o.assigned_agent_name || "—"}</td>
                    <td className="py-2">{formatSla(o.sla_remaining_seconds)}</td>
                    <td className="py-2">{o.last_evidence_type || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {unassigned.length === 0 ? (
            <div className="text-sm text-muted-foreground">Sin casos sin asignar en este momento.</div>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  <th className="pb-2">Oportunidad</th>
                  <th className="pb-2">Propiedad</th>
                  <th className="pb-2">Ultima evidencia</th>
                  <th className="pb-2">Detectado</th>
                </tr>
              </thead>
              <tbody>
                {unassigned.map((o) => (
                  <tr key={o.opportunity_id} className="border-t border-foreground/10">
                    <td className="py-2 font-semibold">#{o.opportunity_id}</td>
                    <td className="py-2">{o.property_id || "—"}</td>
                    <td className="py-2">{o.last_evidence_type || "—"}</td>
                    <td className="py-2">{new Date(o.detected_at).toLocaleString("es-MX")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}
