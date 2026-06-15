import { LeadsTable } from "@/components/leads-table";
import { getRecentConversations } from "@/lib/queries";

export const dynamic = "force-dynamic";

export default async function LeadsPage() {
  const conversations = await getRecentConversations(50);

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Leads en Vivo</h2>
          <div className="text-xs text-muted-foreground">Actualizacion en tiempo real via Supabase Realtime</div>
        </div>
      </div>

      <LeadsTable conversations={conversations} />
    </div>
  );
}
