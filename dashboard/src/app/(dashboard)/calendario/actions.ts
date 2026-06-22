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

  // Business rule: the same agent cannot cover both morning and afternoon on
  // the same day (one person on guard in the morning, a different one in the
  // afternoon). Enforced here so a stale client cannot bypass the UI check.
  const conflicts = scheduleData
    .filter((d) => {
      const m = d.morning.filter(Boolean);
      const t = d.afternoon.filter(Boolean);
      return m.length > 0 && t.length > 0 && m.some((a) => t.includes(a));
    })
    .map((d) => d.date);
  if (conflicts.length > 0) {
    return {
      success: false,
      error: `Mismo agente en manana y tarde: ${conflicts.join(", ")}`,
    };
  }

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

  if (rows.length === 0) return { success: true, inserted: 0 };

  // C5 fix: Use atomic RPC function (DELETE + INSERT in single transaction)
  const { data, error } = await supabase.rpc("save_month_schedule", {
    p_first_date: firstDate,
    p_last_date: lastDate,
    p_rows: rows,
  });

  if (error) return { success: false, error: error.message };

  return { success: true, inserted: data as number };
}
