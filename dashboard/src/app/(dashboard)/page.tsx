import { KPICards } from "@/components/kpi-cards";
import { SourceChart } from "@/components/source-chart";
import { LeadsTable } from "@/components/leads-table";
import { getKPIs, getRecentConversations } from "@/lib/queries";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const [kpis, recentLeads] = await Promise.all([
    getKPIs(),
    getRecentConversations(10),
  ]);

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
    </div>
  );
}
