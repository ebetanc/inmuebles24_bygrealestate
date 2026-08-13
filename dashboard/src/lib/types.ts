export type AgentRole = "owner" | "manager" | "asesor";

export interface Agent {
  agent_id: string;
  name: string;
  whatsapp_number: string;
  easybroker_email: string | null;
  is_available: boolean;
  on_shift: boolean;
  shift_slot: "morning" | "afternoon" | null;
  role: AgentRole;
}
export interface Conversation {
  conversation_id: string;
  lead_phone: string;
  lead_name: string | null;
  lead_email: string | null;
  current_property: string | null;
  mode: string;
  source: "inmuebles24" | "easybroker" | "whatsapp_direct";
  arrived_during: "day" | "night";
  assigned_agent_id: string | null;
  agent_name: string | null;
  created_at: string;
  last_message_at: string | null;
}

export interface Auction {
  auction_id: string;
  conversation_id: string;
  short_code: string;
  status: string;
  created_at: string;
  expires_at: string;
  claimed_by: string | null;
  lead_name?: string;
  property_title?: string;
}

export interface NightQueueItem {
  id: number;
  conversation_id: string;
  source: string;
  lead_phone: string;
  lead_name: string | null;
  lead_email: string | null;
  property_id: string | null;
  temperature: string | null;
  bot_summary: string | null;
  processed: boolean;
  queued_at: string;
}

export interface GuardShift {
  id: number;
  schedule_date: string;
  shift: string;
  agent_id: string;
  coverage_role: "primary" | "backup" | null;
  agents?: { name: string };
}

export interface ScrapeRun {
  id: number;
  run_id: string;
  started_at: string;
  completed_at: string | null;
  status: string;
  total_scraped: number;
  new_listings: number;
  duplicates: number;
  pages_scraped: number;
  error_message: string | null;
  notifications_sent: boolean;
  metadata: Record<string, unknown> | null;
  created_at: string;
}

export interface SLABreach {
  conversation_id: string;
  lead_name: string | null;
  lead_phone: string;
  assigned_agent_id: string;
  agent_name: string;
  assigned_at: string;
  pending_seconds: number;
  stage: string;
}

// LRV2-014: routing-v2 pilot observability. Mirrors routing_v2_ops_view.
export interface RoutingV2OpsRow {
  opportunity_id: number;
  state: string;
  routing_tier: "owner" | "primary_guard" | "backup_guard" | null;
  assigned_agent_id: string | null;
  assigned_agent_name: string | null;
  conversation_id: string | null;
  conversation_source: string | null;
  property_id: string | null;
  detected_at: string;
  delivered_at: string | null;
  expires_at: string | null;
  sla_remaining_seconds: number | null;
  is_unassigned: boolean;
  last_evidence_type: string | null;
  last_evidence_at: string | null;
  last_evidence: Record<string, unknown> | null;
}

// Mirrors get_routing_v2_kpis(); values are null until enough data exists.
export interface RoutingV2KPIs {
  generated_at: string;
  days: number;
  avg_detection_to_delivery_seconds: number | null;
  avg_delivery_to_acceptance_seconds: number | null;
  avg_total_seconds: number | null;
  acceptance_rate_by_tier: Record<string, number>;
  escalations: number;
  late_claims: number;
  failures_by_integration: {
    whatsapp: number;
    inmuebles24: number;
    easybroker: number;
  };
  unassigned_cases_open: number;
  unassigned_cases_in_window: number;
}

export interface KPIs {
  totalLeadsToday: number;
  totalLeadsWeek: number;
  activeAuctions: number;
  nightQueuePending: number;
  avgResponseMin: number;
  conversionRate: number;
  slaBreachesCount: number;
  bySource: {
    inmuebles24: number;
    easybroker: number;
    whatsapp_direct: number;
  };
}
