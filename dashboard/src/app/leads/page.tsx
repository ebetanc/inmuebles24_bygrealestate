import { LeadsTable } from "@/components/leads-table";
import { getRecentConversations } from "@/lib/queries";

export const dynamic = "force-dynamic";

export default async function LeadsPage() {
  const conversations = await getRecentConversations(50);

  return (
    <div>
      <div className="mb-5 flex items-center justify-between">
        <div>
          <h2 className="text-base font-bold text-[#0F172A]">Leads en Vivo</h2>
          <div className="text-xs text-[#94A3B8]">Actualizacion en tiempo real via Supabase Realtime</div>
        </div>
      </div>

      <div className="rounded-xl border border-[#E2E8F0] bg-white overflow-hidden">
        <LeadsTable conversations={conversations} />
      </div>
    </div>
  );
}
