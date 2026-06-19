"use server";

import { createSupabaseServer } from "@/lib/supabase";

export interface AgentInput {
  agent_id?: string; // only used on create; ignored on update
  name: string;
  whatsapp_number: string;
  easybroker_email: string | null;
  shift_slot: "morning" | "afternoon" | null;
  aliases: string[];
}

type Result = { success: true; warnings?: string[] } | { success: false; error: string };

// Strip accents + non-alphanumerics -> kebab; used to derive agent_id from name.
function slugify(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

// Canonical stored format = 521 + 10-digit national (Evolution send format, matches
// every existing row). Manager enters the 10-digit local number; we also accept a pasted
// 521... (13) or 52... (12) and canonicalize. Returns null if not 10 national digits.
function canonicalWhatsapp(raw: string): string | null {
  const d = (raw || "").replace(/[^\d]/g, "");
  if (/^\d{10}$/.test(d)) return `521${d}`;
  if (/^521\d{10}$/.test(d)) return d;
  if (/^52\d{10}$/.test(d)) return `521${d.slice(2)}`;
  return null;
}

function normalizeAliases(tags: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const t of tags) {
    const n = t.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
    if (n && !seen.has(n)) {
      seen.add(n);
      out.push(n);
    }
  }
  return out;
}

// Returns { wa } on success or { error } on failure.
function validate(input: AgentInput): { wa: string } | { error: string } {
  if (!input.name?.trim()) return { error: "El nombre es obligatorio" };
  if (!input.whatsapp_number?.trim()) return { error: "El numero de WhatsApp es obligatorio" };
  const wa = canonicalWhatsapp(input.whatsapp_number);
  if (!wa) return { error: "WhatsApp invalido — escribe los 10 digitos del numero" };
  return { wa };
}

// Replace the agent's full alias set. tag_normalized is a global PK (one tag -> one
// agent), so re-assigning a tag owned by someone else upserts it. Returns warnings for
// any reassignments so the UI can surface them.
async function writeAliases(
  supabase: ReturnType<typeof createSupabaseServer>,
  agentId: string,
  tags: string[]
): Promise<string[]> {
  const normalized = normalizeAliases(tags);
  const warnings: string[] = [];

  // Detect tags currently owned by a different agent (will be reassigned).
  if (normalized.length > 0) {
    const { data: existing } = await supabase
      .from("property_agent_alias")
      .select("tag_normalized, agent_id")
      .in("tag_normalized", normalized);
    for (const row of (existing || []) as { tag_normalized: string; agent_id: string }[]) {
      if (row.agent_id !== agentId) {
        warnings.push(`tag "${row.tag_normalized}" reasignado de ${row.agent_id}`);
      }
    }
  }

  // Remove this agent's current tags, then upsert the new set (reassigns collisions).
  await supabase.from("property_agent_alias").delete().eq("agent_id", agentId);
  if (normalized.length > 0) {
    const rows = normalized.map((tag_normalized) => ({ tag_normalized, agent_id: agentId }));
    const { error } = await supabase
      .from("property_agent_alias")
      .upsert(rows, { onConflict: "tag_normalized" });
    if (error) warnings.push(`Error guardando aliases: ${error.message}`);
  }
  return warnings;
}

export async function createAgent(input: AgentInput): Promise<Result> {
  const v = validate(input);
  if ("error" in v) return { success: false, error: v.error };
  const wa = v.wa;

  const supabase = createSupabaseServer();
  const agentId = (input.agent_id?.trim() || `agent_${slugify(input.name)}`).trim();
  if (!agentId || agentId === "agent_") return { success: false, error: "agent_id invalido" };

  const { error } = await supabase.from("agents").insert({
    agent_id: agentId,
    name: input.name.trim(),
    whatsapp_number: wa,
    easybroker_email: input.easybroker_email?.trim() || null,
    shift_slot: input.shift_slot,
    is_available: true,
    on_shift: false,
  });

  if (error) {
    if (error.code === "23505") {
      return { success: false, error: "Ya existe un agente con ese ID o numero de WhatsApp" };
    }
    return { success: false, error: error.message };
  }

  const warnings = await writeAliases(supabase, agentId, input.aliases);
  return { success: true, warnings };
}

export async function updateAgent(agentId: string, input: AgentInput): Promise<Result> {
  const v = validate(input);
  if ("error" in v) return { success: false, error: v.error };
  const wa = v.wa;

  const supabase = createSupabaseServer();

  const { error } = await supabase
    .from("agents")
    .update({
      name: input.name.trim(),
      whatsapp_number: wa,
      easybroker_email: input.easybroker_email?.trim() || null,
      shift_slot: input.shift_slot,
    })
    .eq("agent_id", agentId);

  if (error) {
    if (error.code === "23505") {
      return { success: false, error: "Ese numero de WhatsApp ya esta en uso" };
    }
    return { success: false, error: error.message };
  }

  const warnings = await writeAliases(supabase, agentId, input.aliases);
  return { success: true, warnings };
}

export async function setAgentAvailability(
  agentId: string,
  isAvailable: boolean
): Promise<Result> {
  const supabase = createSupabaseServer();
  const update: { is_available: boolean; on_shift?: boolean } = { is_available: isAvailable };
  // Deactivating also clears on_shift so a departed agent never looks "en turno".
  if (!isAvailable) update.on_shift = false;
  const { error } = await supabase.from("agents").update(update).eq("agent_id", agentId);
  if (error) return { success: false, error: error.message };
  return { success: true };
}
