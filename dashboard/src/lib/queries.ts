import { createSupabaseServer } from "./supabase";
import type { Agent, Conversation, Auction, NightQueueItem, KPIs, ScrapeRun, SLABreach, RoutingV2OpsRow, RoutingV2KPIs } from "./types";
import { mxStartOfToday, mxToday } from "./datetime";

const db = () => createSupabaseServer();

export async function getKPIs(): Promise<KPIs> {
  const supabase = db();
  const todayStart = mxStartOfToday();
  const weekStart = new Date();
  weekStart.setDate(weekStart.getDate() - 7);

  const [todayRes, weekRes, auctionRes, nightRes, sourceRes, slaRes, metricsRes] = await Promise.all([
    supabase
      .from("conversations")
      .select("conversation_id", { count: "exact", head: true })
      .gte("created_at", todayStart.toISOString()),
    supabase
      .from("conversations")
      .select("conversation_id", { count: "exact", head: true })
      .gte("created_at", weekStart.toISOString()),
    supabase
      .from("auctions")
      .select("auction_id", { count: "exact", head: true })
      .eq("status", "open"),
    supabase
      .from("night_queue")
      .select("id", { count: "exact", head: true })
      .eq("processed", false),
    supabase
      .from("conversations")
      .select("source, mode, assigned_agent_id, assigned_at, first_response_at")
      .gte("created_at", weekStart.toISOString()),
    supabase
      .from("sla_breaches")
      .select("conversation_id", { count: "exact", head: true }),
    supabase
      .from("agent_metrics")
      .select("avg_response_sec_30d"),
  ]);

  const convList = (sourceRes.data || []) as {
    source: string;
    mode: string;
    assigned_agent_id: string | null;
    assigned_at: string | null;
    first_response_at: string | null;
  }[];

  const bySource = {
    inmuebles24: convList.filter((s) => s.source === "inmuebles24").length,
    easybroker: convList.filter((s) => s.source === "easybroker").length,
    whatsapp_direct: convList.filter((s) => s.source === "whatsapp_direct").length,
  };

  const assignedCount = convList.filter((c) => c.assigned_agent_id !== null || c.mode === "assigned" || c.mode === "human").length;
  const conversionRate = convList.length > 0 ? Math.round((assignedCount / convList.length) * 100) : 0;

  let avgResponseMin = 0;
  const metrics = (metricsRes.data || []) as { avg_response_sec_30d: number | null }[];
  const validMetrics = metrics.map((m) => m.avg_response_sec_30d).filter((sec): sec is number => typeof sec === "number" && sec > 0);
  if (validMetrics.length > 0) {
    const avgSec = validMetrics.reduce((a, b) => a + b, 0) / validMetrics.length;
    avgResponseMin = Math.round(avgSec / 60);
  } else {
    const responseTimesSec = convList
      .filter((c) => c.assigned_at && c.first_response_at)
      .map((c) => (new Date(c.first_response_at!).getTime() - new Date(c.assigned_at!).getTime()) / 1000)
      .filter((sec) => sec > 0);

    if (responseTimesSec.length > 0) {
      avgResponseMin = Math.round(responseTimesSec.reduce((a, b) => a + b, 0) / responseTimesSec.length / 60);
    }
  }

  return {
    totalLeadsToday: todayRes.count || 0,
    totalLeadsWeek: weekRes.count || 0,
    activeAuctions: auctionRes.count || 0,
    nightQueuePending: nightRes.count || 0,
    avgResponseMin,
    conversionRate,
    slaBreachesCount: slaRes.count || 0,
    bySource,
  };
}

export async function getSLABreaches(): Promise<SLABreach[]> {
  const supabase = db();
  const { data } = await supabase
    .from("sla_breaches")
    .select("*")
    .order("pending_seconds", { ascending: false });
  return (data || []) as SLABreach[];
}

export async function getRecentConversations(limit = 20): Promise<Conversation[]> {
  const supabase = db();
  // conversations has TWO FKs to agents (assigned_agent_id + owner_agent_id),
  // so an unqualified `agents(name)` embed is ambiguous and PostgREST errors out
  // (PGRST201) — which silently returned zero leads. Pin the embed to the
  // assigned-agent FK by constraint name.
  const { data } = await supabase
    .from("conversations")
    .select("*, agents!conversations_assigned_agent_id_fkey(name)")
    .order("created_at", { ascending: false })
    .limit(limit);
  return ((data || []) as (Conversation & { agents: { name: string } | null })[]).map(
    ({ agents: agentRow, ...rest }) => ({
      ...rest,
      agent_name: agentRow?.name || null,
    })
  );
}

export async function getAgents(): Promise<Agent[]> {
  const supabase = db();
  const { data } = await supabase
    .from("agents")
    .select("*")
    .eq("is_available", true)
    .order("name");
  return (data || []) as Agent[];
}

// Full roster incl. deactivated agents — for the management UI only.
// (getAgents() stays active-only; calendar + routing depend on that filter.)
export async function getAllAgents(): Promise<Agent[]> {
  const supabase = db();
  const { data } = await supabase
    .from("agents")
    .select("*")
    .order("is_available", { ascending: false })
    .order("name");
  return (data || []) as Agent[];
}

// agent_id -> list of property tags (property_agent_alias) for owner routing.
export async function getAgentAliases(): Promise<Record<string, string[]>> {
  const supabase = db();
  const { data } = await supabase
    .from("property_agent_alias")
    .select("tag_normalized, agent_id")
    .order("tag_normalized");
  const map: Record<string, string[]> = {};
  for (const row of (data || []) as { tag_normalized: string; agent_id: string }[]) {
    (map[row.agent_id] ||= []).push(row.tag_normalized);
  }
  return map;
}

export async function getAgentStats(agentId: string) {
  const supabase = db();
  const weekStart = new Date();
  weekStart.setDate(weekStart.getDate() - 7);

  const { count } = await supabase
    .from("conversations")
    .select("conversation_id", { count: "exact", head: true })
    .eq("assigned_agent_id", agentId)
    .gte("created_at", weekStart.toISOString());

  return { leadsThisWeek: count || 0 };
}

export async function getActiveAuctions(): Promise<Auction[]> {
  const supabase = db();
  const { data } = await supabase
    .from("auctions")
    .select("*")
    .eq("status", "open")
    .order("created_at", { ascending: false });
  return (data || []) as Auction[];
}

export async function getNightQueue(): Promise<NightQueueItem[]> {
  const supabase = db();
  const { data } = await supabase
    .from("night_queue")
    .select("*")
    .eq("processed", false)
    .order("queued_at", { ascending: false });
  return (data || []) as NightQueueItem[];
}

// Bitácora de corridas del scraper (Pi) — una fila por corrida cada 15 min,
// incluso si no trajo ningún lead. Fuente: tabla scrape_logs.
export async function getScrapeRuns(limit = 100): Promise<ScrapeRun[]> {
  const supabase = db();
  const { data } = await supabase
    .from("scrape_logs")
    .select("*")
    .order("started_at", { ascending: false })
    .limit(limit);
  return (data || []) as ScrapeRun[];
}

export async function getGuardSchedule() {
  const supabase = db();
  const today = mxToday();
  const endDate = new Date();
  endDate.setDate(endDate.getDate() + 7);

  const { data } = await supabase
    .from("agent_schedule")
    .select("*, agents(name)")
    .gte("schedule_date", today)
    .lte("schedule_date", endDate.toISOString().split("T")[0])
    .order("schedule_date")
    .order("shift");
  return data || [];
}

// LRV2-014: routing-v2 pilot observability. State/SLA/evidence come from the
// DB view (routing_v2_ops_view), never from n8n workflow memory.
export async function getRoutingV2Ops(): Promise<RoutingV2OpsRow[]> {
  const supabase = db();
  const { data } = await supabase
    .from("routing_v2_ops_view")
    .select("*")
    .order("detected_at", { ascending: false });
  return (data || []) as RoutingV2OpsRow[];
}

export async function getRoutingV2KPIs(daysBack = 7): Promise<RoutingV2KPIs> {
  const supabase = db();
  const { data } = await supabase.rpc("get_routing_v2_kpis", { p_days_back: daysBack });
  return data as RoutingV2KPIs;
}

export async function getMonthSchedule(year: number, month: number) {
  const supabase = db();
  const startDate = `${year}-${String(month).padStart(2, "0")}-01`;
  const lastDay = new Date(year, month, 0).getDate();
  const endDate = `${year}-${String(month).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}`;

  const { data } = await supabase
    .from("agent_schedule")
    .select("id, schedule_date, shift, agent_id, coverage_role")
    .gte("schedule_date", startDate)
    .lte("schedule_date", endDate)
    .order("schedule_date")
    .order("shift");
  return (data || []) as { id: number; schedule_date: string; shift: string; agent_id: string; coverage_role: "primary" | "backup" | null }[];
}
