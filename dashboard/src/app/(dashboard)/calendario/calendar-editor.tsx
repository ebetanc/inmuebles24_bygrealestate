"use client";

import { useState, useCallback, useTransition, useEffect } from "react";
import { useRouter } from "next/navigation";
import { saveMonthSchedule } from "./actions";

interface Agent {
  agent_id: string;
  name: string;
}

interface ScheduleRow {
  schedule_date: string;
  shift: string;
  agent_id: string;
}

interface DayData {
  m1: string;
  m2: string;
  t1: string;
  t2: string;
}

const DAY_NAMES = ["Dom", "Lun", "Mar", "Mie", "Jue", "Vie", "Sab"];
const MONTH_NAMES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

const AGENT_COLORS: Record<string, string> = {};
const PALETTE = ["#3B82F6", "#8B5CF6", "#F59E0B", "#EC4899", "#22C55E", "#06B6D4"];

function getDaysInMonth(year: number, month: number) {
  return new Date(year, month, 0).getDate();
}

function buildInitialState(
  year: number,
  month: number,
  existing: ScheduleRow[]
): Record<string, DayData> {
  const days = getDaysInMonth(year, month);
  const state: Record<string, DayData> = {};

  for (let d = 1; d <= days; d++) {
    const date = `${year}-${String(month).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
    state[date] = { m1: "", m2: "", t1: "", t2: "" };
  }

  // Group existing data by date+shift
  const byDateShift = new Map<string, string[]>();
  for (const row of existing) {
    const key = `${row.schedule_date}|${row.shift}`;
    if (!byDateShift.has(key)) byDateShift.set(key, []);
    byDateShift.get(key)!.push(row.agent_id);
  }

  for (const [key, agents] of byDateShift) {
    const [date, shift] = key.split("|");
    if (!state[date]) continue;
    if (shift === "morning") {
      state[date].m1 = agents[0] || "";
      state[date].m2 = agents[1] || "";
    } else {
      state[date].t1 = agents[0] || "";
      state[date].t2 = agents[1] || "";
    }
  }

  return state;
}

function countShifts(schedule: Record<string, DayData>, agents: Agent[]) {
  const counts: Record<string, { morning: number; afternoon: number }> = {};
  for (const a of agents) counts[a.agent_id] = { morning: 0, afternoon: 0 };
  for (const day of Object.values(schedule)) {
    if (day.m1 && counts[day.m1]) counts[day.m1].morning++;
    if (day.m2 && counts[day.m2]) counts[day.m2].morning++;
    if (day.t1 && counts[day.t1]) counts[day.t1].afternoon++;
    if (day.t2 && counts[day.t2]) counts[day.t2].afternoon++;
  }
  return counts;
}

function hasDuplicate(day: DayData): string | null {
  const slots = [day.m1, day.m2, day.t1, day.t2].filter(Boolean);
  const seen = new Set<string>();
  for (const s of slots) {
    if (seen.has(s)) return s;
    seen.add(s);
  }
  return null;
}

export default function CalendarEditor({
  agents,
  initialSchedule,
  initialYear,
  initialMonth,
}: {
  agents: Agent[];
  initialSchedule: ScheduleRow[];
  initialYear: number;
  initialMonth: number;
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [year, setYear] = useState(initialYear);
  const [month, setMonth] = useState(initialMonth);
  const [schedule, setSchedule] = useState(() =>
    buildInitialState(initialYear, initialMonth, initialSchedule)
  );
  const [toast, setToast] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);

  // Sync state when server sends new props (month navigation)
  useEffect(() => {
    setYear(initialYear);
    setMonth(initialMonth);
    setSchedule(buildInitialState(initialYear, initialMonth, initialSchedule));
    setDirty(false);
  }, [initialYear, initialMonth, initialSchedule]);

  // Assign colors
  agents.forEach((a, i) => {
    AGENT_COLORS[a.agent_id] = PALETTE[i % PALETTE.length];
  });

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 3000);
  }, []);

  const changeMonth = (newYear: number, newMonth: number) => {
    router.push(`/calendario?y=${newYear}&m=${newMonth}`);
  };

  const updateSlot = (date: string, slot: keyof DayData, value: string) => {
    setSchedule((prev) => ({
      ...prev,
      [date]: { ...prev[date], [slot]: value },
    }));
    setDirty(true);
  };

  const autoFillRotation = () => {
    const pairs: [string, string][] = [];
    for (let i = 0; i < agents.length; i += 2) {
      if (agents[i + 1]) {
        pairs.push([agents[i].agent_id, agents[i + 1].agent_id]);
      }
    }
    if (pairs.length < 2) return;

    const newSchedule = { ...schedule };
    let idx = 0;
    for (const date of Object.keys(newSchedule).sort()) {
      const mPair = pairs[idx % pairs.length];
      const tPair = pairs[(idx + 1) % pairs.length];
      newSchedule[date] = {
        m1: mPair[0],
        m2: mPair[1],
        t1: tPair[0],
        t2: tPair[1],
      };
      idx++;
    }
    setSchedule(newSchedule);
    setDirty(true);
    showToast("Rotacion aplicada — revise y ajuste antes de guardar");
  };

  const clearAll = () => {
    if (!confirm("Limpiar todas las asignaciones del mes?")) return;
    setSchedule(buildInitialState(year, month, []));
    setDirty(true);
  };

  const handleSave = () => {
    const data = Object.entries(schedule).map(([date, day]) => ({
      date,
      morning: [day.m1, day.m2].filter(Boolean),
      afternoon: [day.t1, day.t2].filter(Boolean),
    }));

    startTransition(async () => {
      const result = await saveMonthSchedule(data);
      if (result.success) {
        showToast(`Guardado — ${result.inserted} asignaciones`);
        setDirty(false);
        router.refresh();
      } else {
        showToast(`Error: ${result.error}`);
      }
    });
  };

  const dates = Object.keys(schedule).sort();
  const today = new Date().toISOString().split("T")[0];
  const stats = countShifts(schedule, agents);
  const filledSlots = Object.values(schedule).reduce(
    (n, d) => n + [d.m1, d.m2, d.t1, d.t2].filter(Boolean).length,
    0
  );
  const totalSlots = dates.length * 4;
  const pct = totalSlots > 0 ? Math.round((filledSlots / totalSlots) * 100) : 0;

  const prevMonth = month === 1 ? { y: year - 1, m: 12 } : { y: year, m: month - 1 };
  const nextMonth = month === 12 ? { y: year + 1, m: 1 } : { y: year, m: month + 1 };

  return (
    <div>
      {/* Header */}
      <div className="mb-5 flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 className="text-base font-bold text-[#0F172A]">Calendario de Guardias</h2>
          <div className="text-xs text-[#94A3B8]">
            Asigne 2 agentes por turno por dia — los cambios se guardan en Supabase
          </div>
        </div>
        <div className="flex items-center gap-2">
          {dirty && (
            <span className="text-xs font-semibold text-[#F59E0B] bg-[#FFFBEB] px-2 py-1 rounded-md">
              Sin guardar
            </span>
          )}
          <button
            onClick={handleSave}
            disabled={isPending || !dirty}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#22C55E] px-4 py-2 text-xs font-bold text-white hover:bg-[#16A34A] disabled:opacity-40 disabled:cursor-not-allowed transition-all"
          >
            {isPending ? "Guardando..." : "Guardar mes"}
          </button>
        </div>
      </div>

      {/* Controls */}
      <div className="flex flex-wrap items-center gap-3 bg-white rounded-xl border border-[#E2E8F0] px-4 py-3 mb-4">
        <button
          onClick={() => changeMonth(prevMonth.y, prevMonth.m)}
          className="px-2.5 py-1 rounded-lg border border-[#E2E8F0] text-sm font-bold text-[#64748B] hover:bg-[#F8FAFC] transition-colors"
        >
          &larr;
        </button>
        <span className="text-sm font-bold text-[#0F172A] min-w-[140px] text-center">
          {MONTH_NAMES[month - 1]} {year}
        </span>
        <button
          onClick={() => changeMonth(nextMonth.y, nextMonth.m)}
          className="px-2.5 py-1 rounded-lg border border-[#E2E8F0] text-sm font-bold text-[#64748B] hover:bg-[#F8FAFC] transition-colors"
        >
          &rarr;
        </button>
        <div className="flex-1" />
        <button
          onClick={autoFillRotation}
          className="px-3 py-1.5 rounded-lg border border-[#E2E8F0] text-xs font-semibold text-[#64748B] hover:bg-[#F8FAFC] transition-colors"
        >
          Auto-rotacion
        </button>
        <button
          onClick={clearAll}
          className="px-3 py-1.5 rounded-lg border border-[#FCA5A5] text-xs font-semibold text-[#EF4444] hover:bg-[#FEF2F2] transition-colors"
        >
          Limpiar
        </button>
      </div>

      {/* Legend */}
      <div className="flex flex-wrap gap-4 mb-3 text-xs text-[#64748B]">
        <div className="flex items-center gap-1.5">
          <span className="w-3 h-3 rounded bg-[#FEF3C7]" /> Manana (8–14h)
        </div>
        <div className="flex items-center gap-1.5">
          <span className="w-3 h-3 rounded bg-[#EDE9FE]" /> Tarde (14–21h)
        </div>
        <div className="ml-auto font-semibold text-[#0F172A]">{pct}% completo</div>
      </div>

      {/* Calendar grid */}
      <div className="rounded-xl border border-[#E2E8F0] overflow-hidden bg-white">
        {/* Header row */}
        <div className="grid grid-cols-[100px_1fr_1fr_1fr_1fr] border-b-2 border-[#E2E8F0] bg-[#F8FAFC]">
          <div className="px-3 py-2.5 text-[11px] font-bold uppercase tracking-wide text-[#64748B]">
            Dia
          </div>
          <div className="px-2 py-2.5 text-[11px] font-bold uppercase tracking-wide text-[#B45309] border-l border-[#E2E8F0]">
            Manana 1
          </div>
          <div className="px-2 py-2.5 text-[11px] font-bold uppercase tracking-wide text-[#B45309] border-l border-[#E2E8F0]">
            Manana 2
          </div>
          <div className="px-2 py-2.5 text-[11px] font-bold uppercase tracking-wide text-[#7C3AED] border-l border-[#E2E8F0]">
            Tarde 1
          </div>
          <div className="px-2 py-2.5 text-[11px] font-bold uppercase tracking-wide text-[#7C3AED] border-l border-[#E2E8F0]">
            Tarde 2
          </div>
        </div>

        {/* Day rows */}
        {dates.map((date) => {
          const d = new Date(date + "T12:00:00");
          const dow = d.getDay();
          const isWeekend = dow === 0 || dow === 6;
          const isToday = date === today;
          const day = schedule[date];
          const dup = hasDuplicate(day);

          return (
            <div
              key={date}
              className={`grid grid-cols-[100px_1fr_1fr_1fr_1fr] border-b border-[#F1F5F9] last:border-b-0 ${
                isToday ? "bg-[#EFF6FF]" : isWeekend ? "bg-[#FFFBEB]/40" : ""
              }`}
            >
              {/* Date cell */}
              <div className="flex items-center gap-1.5 px-3 py-2 border-r border-[#F1F5F9] bg-[#FAFBFC]/60">
                <span className="text-sm font-bold text-[#0F172A]">{d.getDate()}</span>
                <span className={`text-[10px] uppercase ${isWeekend ? "text-[#F59E0B] font-bold" : "text-[#94A3B8]"}`}>
                  {DAY_NAMES[dow]}
                </span>
                {isToday && (
                  <span className="rounded bg-[#1D4ED8] px-1 py-0.5 text-[9px] font-bold text-white ml-auto">
                    Hoy
                  </span>
                )}
              </div>

              {/* Slot selects */}
              {(["m1", "m2", "t1", "t2"] as const).map((slot) => {
                const isMorning = slot.startsWith("m");
                const isDup = dup && day[slot] === dup;
                return (
                  <div key={slot} className="px-1.5 py-1.5 border-l border-[#F1F5F9]">
                    <select
                      value={day[slot]}
                      onChange={(e) => updateSlot(date, slot, e.target.value)}
                      className={`w-full px-2 py-1.5 rounded-md text-xs font-semibold border transition-colors cursor-pointer ${
                        isDup
                          ? "border-[#EF4444] bg-[#FEF2F2] text-[#EF4444]"
                          : day[slot]
                          ? isMorning
                            ? "border-[#FDE68A] bg-[#FEF3C7] text-[#92400E]"
                            : "border-[#C4B5FD] bg-[#EDE9FE] text-[#5B21B6]"
                          : "border-[#E2E8F0] bg-white text-[#94A3B8]"
                      } focus:outline-none focus:ring-2 ${isMorning ? "focus:ring-[#F59E0B]/30" : "focus:ring-[#8B5CF6]/30"}`}
                    >
                      <option value="">--</option>
                      {agents.map((a) => (
                        <option key={a.agent_id} value={a.agent_id}>
                          {a.name}
                        </option>
                      ))}
                    </select>
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-7 gap-3 mt-5">
        <div className="bg-white rounded-xl border border-[#E2E8F0] p-4 text-center">
          <div className="text-2xl font-extrabold text-[#3B82F6]">{pct}%</div>
          <div className="text-[10px] font-semibold uppercase tracking-wide text-[#94A3B8]">Completo</div>
        </div>
        {agents.map((a) => {
          const s = stats[a.agent_id] || { morning: 0, afternoon: 0 };
          return (
            <div key={a.agent_id} className="bg-white rounded-xl border border-[#E2E8F0] p-4 text-center">
              <div className="text-2xl font-extrabold" style={{ color: AGENT_COLORS[a.agent_id] }}>
                {s.morning + s.afternoon}
              </div>
              <div className="text-[10px] font-semibold uppercase tracking-wide text-[#94A3B8]">
                {a.name}
              </div>
              <div className="text-[10px] text-[#94A3B8] mt-0.5">
                <span className="text-[#F59E0B]">{s.morning}m</span>
                {" / "}
                <span className="text-[#8B5CF6]">{s.afternoon}t</span>
              </div>
            </div>
          );
        })}
      </div>

      {/* Toast */}
      {toast && (
        <div className="fixed bottom-6 right-6 bg-[#0F172A] text-white px-4 py-2.5 rounded-lg text-sm font-medium shadow-lg animate-fade-in z-50">
          {toast}
        </div>
      )}
    </div>
  );
}
