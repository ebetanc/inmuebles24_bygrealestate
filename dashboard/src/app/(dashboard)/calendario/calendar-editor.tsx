"use client";

import { useState, useCallback, useTransition, useEffect } from "react";
import { useRouter } from "next/navigation";
import { saveMonthSchedule } from "./actions";
import { mxToday } from "@/lib/datetime";

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
  m: string;
  t: string;
}

const DAY_NAMES = ["Dom", "Lun", "Mar", "Mie", "Jue", "Vie", "Sab"];
const MONTH_NAMES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

const AGENT_COLORS: Record<string, string> = {};
const PALETTE = ["var(--blue)", "var(--orchid)", "var(--amber)", "var(--rose)", "var(--green)", "var(--teal)"];

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
    state[date] = { m: "", t: "" };
  }

  // Group existing data by date+shift (first agent per shift wins)
  for (const row of existing) {
    if (!state[row.schedule_date]) continue;
    if (row.shift === "morning") {
      if (!state[row.schedule_date].m) state[row.schedule_date].m = row.agent_id;
    } else {
      if (!state[row.schedule_date].t) state[row.schedule_date].t = row.agent_id;
    }
  }

  return state;
}

// A day is invalid when the same agent is assigned to both morning and afternoon.
function dayHasConflict(day: DayData): boolean {
  return !!day.m && !!day.t && day.m === day.t;
}

function countShifts(schedule: Record<string, DayData>, agents: Agent[]) {
  const counts: Record<string, { morning: number; afternoon: number }> = {};
  for (const a of agents) counts[a.agent_id] = { morning: 0, afternoon: 0 };
  for (const day of Object.values(schedule)) {
    if (day.m && counts[day.m]) counts[day.m].morning++;
    if (day.t && counts[day.t]) counts[day.t].afternoon++;
  }
  return counts;
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
    if (agents.length < 2) return;

    const newSchedule = { ...schedule };
    let idx = 0;
    for (const date of Object.keys(newSchedule).sort()) {
      // Morning agent and afternoon agent are always different people
      newSchedule[date] = {
        m: agents[idx % agents.length].agent_id,
        t: agents[(idx + 1) % agents.length].agent_id,
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

  const conflictDates = Object.entries(schedule)
    .filter(([, day]) => dayHasConflict(day))
    .map(([date]) => date);

  const handleSave = () => {
    if (conflictDates.length > 0) {
      const d = conflictDates.map((x) => x.slice(8)).join(", ");
      showToast(`Mismo agente en manana y tarde — corrija dia(s): ${d}`);
      return;
    }
    const data = Object.entries(schedule).map(([date, day]) => ({
      date,
      morning: [day.m].filter(Boolean),
      afternoon: [day.t].filter(Boolean),
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
  const today = mxToday();
  const stats = countShifts(schedule, agents);
  const filledSlots = Object.values(schedule).reduce(
    (n, d) => n + [d.m, d.t].filter(Boolean).length,
    0
  );
  const totalSlots = dates.length * 2;
  const pct = totalSlots > 0 ? Math.round((filledSlots / totalSlots) * 100) : 0;

  const prevMonth = month === 1 ? { y: year - 1, m: 12 } : { y: year, m: month - 1 };
  const nextMonth = month === 12 ? { y: year + 1, m: 1 } : { y: year, m: month + 1 };

  return (
    <div>
      {/* Header */}
      <div className="mb-5 flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 className="font-display text-base font-bold text-foreground">Calendario de Guardias</h2>
          <div className="text-xs text-muted-foreground">
            Asigne 1 agente por turno por dia — los cambios se guardan en Supabase
          </div>
        </div>
        <div className="flex items-center gap-2">
          {conflictDates.length > 0 && (
            <span className="nb-chip is-alert">
              {conflictDates.length} dia(s) con agente repetido
            </span>
          )}
          {dirty && conflictDates.length === 0 && (
            <span className="nb-chip is-accent">
              Sin guardar
            </span>
          )}
          <button
            onClick={handleSave}
            disabled={isPending || !dirty || conflictDates.length > 0}
            className="inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-primary px-4 py-2 font-display text-xs font-bold text-primary-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-foreground hover:text-background hover:shadow-[var(--shadow-hover)] disabled:opacity-40 disabled:cursor-not-allowed disabled:shadow-none disabled:hover:translate-x-0 disabled:hover:translate-y-0"
          >
            {isPending ? "Guardando..." : "Guardar mes"}
          </button>
        </div>
      </div>

      {/* Controls */}
      <div className="flex flex-wrap items-center gap-3 bg-card rounded-[var(--radius)] border-2 border-foreground shadow-[var(--shadow-sm)] px-4 py-3 mb-4">
        <button
          onClick={() => changeMonth(prevMonth.y, prevMonth.m)}
          className="px-2.5 py-1 rounded-[var(--radius-sm)] border-2 border-foreground bg-card font-display text-sm font-bold text-foreground hover:bg-accent transition-colors"
        >
          &larr;
        </button>
        <span className="font-display text-sm font-bold text-foreground min-w-[140px] text-center">
          {MONTH_NAMES[month - 1]} {year}
        </span>
        <button
          onClick={() => changeMonth(nextMonth.y, nextMonth.m)}
          className="px-2.5 py-1 rounded-[var(--radius-sm)] border-2 border-foreground bg-card font-display text-sm font-bold text-foreground hover:bg-accent transition-colors"
        >
          &rarr;
        </button>
        <div className="flex-1" />
        <button
          onClick={autoFillRotation}
          className="px-3 py-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-card font-display text-xs font-bold text-foreground hover:bg-accent transition-colors"
        >
          Auto-rotacion
        </button>
        <button
          onClick={clearAll}
          className="px-3 py-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-destructive font-display text-xs font-bold text-destructive-foreground hover:bg-foreground hover:text-background transition-colors"
        >
          Limpiar
        </button>
      </div>

      {/* Legend */}
      <div className="flex flex-wrap gap-4 mb-3 text-xs font-medium text-muted-foreground">
        <div className="flex items-center gap-1.5">
          <span className="w-3.5 h-3.5 rounded-[3px] border-2 border-foreground bg-[var(--accent-fill)]" /> Manana (8–14h)
        </div>
        <div className="flex items-center gap-1.5">
          <span className="w-3.5 h-3.5 rounded-[3px] border-2 border-foreground bg-[var(--neutral)]" /> Tarde (14–21h)
        </div>
        <div className="ml-auto font-mono font-bold text-foreground">{pct}% completo</div>
      </div>

      {/* Calendar grid */}
      <div className="rounded-[var(--radius)] border-2 border-foreground overflow-hidden bg-card shadow-[var(--shadow-sm)]">
        {/* Header row */}
        <div className="grid grid-cols-[100px_1fr_1fr] border-b-2 border-foreground bg-[var(--neutral)]">
          <div className="px-3 py-2.5 font-display text-[11px] font-extrabold uppercase tracking-[0.08em] text-foreground">
            Dia
          </div>
          <div className="px-2 py-2.5 font-display text-[11px] font-extrabold uppercase tracking-[0.08em] text-foreground border-l-2 border-foreground">
            Manana
          </div>
          <div className="px-2 py-2.5 font-display text-[11px] font-extrabold uppercase tracking-[0.08em] text-foreground border-l-2 border-foreground">
            Tarde
          </div>
        </div>

        {/* Day rows */}
        {dates.map((date) => {
          const d = new Date(date + "T12:00:00");
          const dow = d.getDay();
          const isWeekend = dow === 0 || dow === 6;
          const isToday = date === today;
          const day = schedule[date];
          const conflict = dayHasConflict(day);

          return (
            <div
              key={date}
              className={`grid grid-cols-[100px_1fr_1fr] border-b border-[var(--line-2)] last:border-b-0 ${
                isToday ? "bg-[var(--neutral)]" : isWeekend ? "bg-[var(--bg-3)]" : ""
              }`}
            >
              {/* Date cell */}
              <div className="flex items-center gap-1.5 px-3 py-2 border-r-2 border-foreground">
                <span className="font-mono text-sm font-bold text-foreground">{d.getDate()}</span>
                <span className={`font-display text-[10px] font-bold uppercase ${isWeekend ? "text-[var(--amber)]" : "text-muted-foreground"}`}>
                  {DAY_NAMES[dow]}
                </span>
                {isToday && (
                  <span className="rounded-[6px] border-2 border-foreground bg-primary px-1 py-0.5 font-display text-[9px] font-extrabold text-foreground ml-auto">
                    Hoy
                  </span>
                )}
              </div>

              {/* Slot selects */}
              {(["m", "t"] as const).map((slot) => {
                const isMorning = slot === "m";
                return (
                  <div key={slot} className="px-1.5 py-1.5 border-l border-[var(--line-2)]">
                    <select
                      value={day[slot]}
                      onChange={(e) => updateSlot(date, slot, e.target.value)}
                      className={`w-full px-2 py-1.5 rounded-[var(--radius-sm)] text-xs font-bold border-2 border-foreground transition-colors cursor-pointer ${
                        conflict
                          ? "bg-destructive text-foreground"
                          : day[slot]
                          ? isMorning
                            ? "bg-[var(--accent-fill)] text-foreground"
                            : "bg-[var(--neutral)] text-foreground"
                          : "bg-card text-muted-foreground"
                      } focus:outline-none focus:-translate-x-px focus:-translate-y-px focus:shadow-[var(--shadow-sm)]`}
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
        <div className="nb nb-hover p-4 text-center">
          <div className="font-mono text-2xl font-bold text-foreground">{pct}%</div>
          <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground">Completo</div>
        </div>
        {agents.map((a) => {
          const s = stats[a.agent_id] || { morning: 0, afternoon: 0 };
          return (
            <div key={a.agent_id} className="nb nb-hover p-4 text-center">
              <div className="font-mono text-2xl font-bold" style={{ color: AGENT_COLORS[a.agent_id] }}>
                {s.morning + s.afternoon}
              </div>
              <div className="font-display text-[10px] font-extrabold uppercase tracking-[0.06em] text-muted-foreground truncate">
                {a.name}
              </div>
              <div className="font-mono text-[10px] text-muted-foreground mt-0.5">
                <span className="text-[var(--amber)]">{s.morning}m</span>
                {" / "}
                <span className="text-[var(--orchid)]">{s.afternoon}t</span>
              </div>
            </div>
          );
        })}
      </div>

      {/* Toast */}
      {toast && (
        <div className="fixed bottom-6 right-6 border-2 border-foreground bg-foreground text-background px-4 py-2.5 rounded-[var(--radius-sm)] font-display text-sm font-bold shadow-[var(--shadow-lg)] animate-fade-in z-50">
          {toast}
        </div>
      )}
    </div>
  );
}
