import { createSupabaseServer } from "./supabase";
import type { Agent, Conversation, Auction, NightQueueItem, KPIs, ScrapeRun } from "./types";

const db = () => createSupabaseServer();

export async function getKPIs(): Promise<KPIs> {
  const supabase = db();
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const weekStart = new Date();
  weekStart.setDate(weekStart.getDate() - 7);

  const [todayRes, weekRes, auctionRes, nightRes, sourceRes] = await Promise.all([
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
      .select("source")
      .gte("created_at", weekStart.toISOString()),
  ]);

  const sources = (sourceRes.data || []) as { source: string }[];
  const bySource = {
    inmuebles24: sources.filter((s) => s.source === "inmuebles24").length,
    easybroker: sources.filter((s) => s.source === "easybroker").length,
    whatsapp_direct: sources.filter((s) => s.source === "whatsapp_direct").length,
  };

  return {
    totalLeadsToday: todayRes.count || 0,
    totalLeadsWeek: weekRes.count || 0,
    activeAuctions: auctionRes.count || 0,
    nightQueuePending: nightRes.count || 0,
    avgResponseMin: 0,
    conversionRate: 0,
    bySource,
  };
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
  const today = new Date().toISOString().split("T")[0];
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

export async function getMonthSchedule(year: number, month: number) {
  const supabase = db();
  const startDate = `${year}-${String(month).padStart(2, "0")}-01`;
  const lastDay = new Date(year, month, 0).getDate();
  const endDate = `${year}-${String(month).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}`;

  const { data } = await supabase
    .from("agent_schedule")
    .select("id, schedule_date, shift, agent_id")
    .gte("schedule_date", startDate)
    .lte("schedule_date", endDate)
    .order("schedule_date")
    .order("shift");
  return (data || []) as { id: number; schedule_date: string; shift: string; agent_id: string }[];
}
