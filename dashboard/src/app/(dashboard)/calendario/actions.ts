"use server";

import { createSupabaseServer } from "@/lib/supabase";

interface DaySchedule {
  date: string; // YYYY-MM-DD
  morning: string[]; // agent_ids
  afternoon: string[]; // agent_ids
}

export async function saveMonthSchedule(scheduleData: DaySchedule[]) {
  const supabase = createSupabaseServer();

  if (scheduleData.length === 0) return { success: false, error: "No data" };
  if (scheduleData.some((day) => day.morning.length > 1 || day.afternoon.length > 1)) {
    return { success: false, error: "V3 permite una sola guardia por turno" };
  }

  // NOTE: It is intentionally ALLOWED for the same agent to cover both morning
  // and afternoon on the same day (full-day coverage — common on weekends with a
  // single advisor on duty). No conflict check here; the DB has no constraint
  // against it either (UNIQUE is on (date, shift, agent), not across shifts).

  // Extract month range from the data
  const dates = scheduleData.map((d) => d.date).sort();
  const firstDate = dates[0];
  const lastDate = dates[dates.length - 1];

  // Build rows for the RPC function
  const rows: { schedule_date: string; shift: string; agent_id: string }[] = [];
  for (const day of scheduleData) {
    for (const agentId of day.morning) {
      if (agentId) rows.push({ schedule_date: day.date, shift: "morning", agent_id: agentId });
    }
    for (const agentId of day.afternoon) {
      if (agentId) rows.push({ schedule_date: day.date, shift: "afternoon", agent_id: agentId });
    }
  }

  // C5 fix: Use atomic RPC function (DELETE + INSERT in single transaction)
  const { data, error } = await supabase.rpc("save_month_schedule", {
    p_first_date: firstDate,
    p_last_date: lastDate,
    p_rows: rows,
  });

  if (error) return { success: false, error: error.message };

  return { success: true, inserted: data as number };
}
