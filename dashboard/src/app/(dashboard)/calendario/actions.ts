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

  // Extract month range from the data
  const dates = scheduleData.map((d) => d.date).sort();
  const firstDate = dates[0];
  const lastDate = dates[dates.length - 1];

  // Delete existing entries for this date range
  const { error: deleteError } = await supabase
    .from("agent_schedule")
    .delete()
    .gte("schedule_date", firstDate)
    .lte("schedule_date", lastDate);

  if (deleteError) return { success: false, error: deleteError.message };

  // Build rows to insert
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

  const { error: insertError } = await supabase.from("agent_schedule").insert(rows);

  if (insertError) return { success: false, error: insertError.message };

  return { success: true, inserted: rows.length };
}
