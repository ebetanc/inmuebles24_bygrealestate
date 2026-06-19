export interface Agent {
  agent_id: string;
  name: string;
  whatsapp_number: string;
  easybroker_email: string | null;
  is_available: boolean;
  on_shift: boolean;
  shift_slot: "morning" | "afternoon" | null;
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
  agents?: { name: string };
}

export interface KPIs {
  totalLeadsToday: number;
  totalLeadsWeek: number;
  activeAuctions: number;
  nightQueuePending: number;
  avgResponseMin: number;
  conversionRate: number;
  bySource: {
    inmuebles24: number;
    easybroker: number;
    whatsapp_direct: number;
  };
}
