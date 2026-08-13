"use client";

import { useState, useCallback, useTransition, useEffect, useMemo } from "react";
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
  coverage_role: "primary" | "backup" | null;
}

interface DayData {
  mp: string;
  mb: string;
  tp: string;
  tb: string;
}

const DAY_NAMES = ["Dom", "Lun", "Mar", "Mie", "Jue", "Vie", "Sab"];
const MONTH_NAMES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

const PALETTE = ["var(--blue)", "var(--orchid)", "var(--amber)", "var(--rose)", "var(--green)", "var(--teal)"];

function legacyConflictKeys(existing: ScheduleRow[]): string[] {
  const groups = new Map<string, ScheduleRow[]>();
  for (const row of existing) {
    const key = `${row.schedule_date}:${row.shift}`;
    groups.set(key, [...(groups.get(key) || []), row]);
  }
  return [...groups]
    .filter(([, rows]) => rows.some((row) => row.coverage_role === null) && rows.length > 1)
    .map(([key]) => key);
}

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
    state[date] = { mp: "", mb: "", tp: "", tb: "" };
  }

  const conflicts = new Set(legacyConflictKeys(existing));
  for (const row of existing) {
    if (!state[row.schedule_date]) continue;
    if (conflicts.has(`${row.schedule_date}:${row.shift}`)) continue;
    const slot = row.shift === "morning"
      ? row.coverage_role === "backup" ? "mb" : "mp"
      : row.coverage_role === "backup" ? "tb" : "tp";
    if (!state[row.schedule_date][slot]) state[row.schedule_date][slot] = row.agent_id;
  }

  return state;
}

// Full-day coverage: the same agent covers both morning and afternoon. This is
// a VALID, intentional arrangement (e.g. weekends with a single advisor on duty
// the whole day). Surfaced as info only — it does NOT block saving.
function dayIsFullDay(day: DayData): boolean {
  return !!day.mp && !!day.tp && day.mp === day.tp;
}

function countShifts(schedule: Record<string, DayData>, agents: Agent[]) {
  const counts: Record<string, { morning: number; afternoon: number }> = {};
  for (const a of agents) counts[a.agent_id] = { morning: 0, afternoon: 0 };
  for (const day of Object.values(schedule)) {
    for (const agentId of [day.mp, day.mb]) if (agentId && counts[agentId]) counts[agentId].morning++;
    for (const agentId of [day.tp, day.tb]) if (agentId && counts[agentId]) counts[agentId].afternoon++;
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
  const [unresolvedLegacy, setUnresolvedLegacy] = useState(() => legacyConflictKeys(initialSchedule));

  // Sync state when server sends new props (month navigation)
  useEffect(() => {
    // Calendar navigation changes server props; reset editor draft to that month.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setYear(initialYear);
    setMonth(initialMonth);
    setSchedule(buildInitialState(initialYear, initialMonth, initialSchedule));
    setUnresolvedLegacy(legacyConflictKeys(initialSchedule));
    setDirty(false);
  }, [initialYear, initialMonth, initialSchedule]);

  const agentColors = useMemo(() => Object.fromEntries(
    agents.map((agent, index) => [agent.agent_id, PALETTE[index % PALETTE.length]])
  ), [agents]);

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
    const shift = slot.startsWith("m") ? "morning" : "afternoon";
    setUnresolvedLegacy((current) => current.filter((key) => key !== `${date}:${shift}`));
    setDirty(true);
  };

  const autoFillRotation = () => {
    if (agents.length < 2) return;

    const newSchedule = { ...schedule };
    let idx = 0;
    for (const date of Object.keys(newSchedule).sort()) {
      const primary = agents[idx % agents.length].agent_id;
      const backup = agents[(idx + 1) % agents.length].agent_id;
      newSchedule[date] = {
        mp: primary,
        mb: backup,
        tp: backup,
        tb: primary,
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
    // Explicit destructive user choice: legacy ambiguity no longer blocks the
    // empty save that clears this month through the atomic RPC.
    setUnresolvedLegacy([]);
    setDirty(true);
  };

  const fullDayDates = Object.entries(schedule)
    .filter(([, day]) => dayIsFullDay(day))
    .map(([date]) => date);

  const handleSave = () => {
    if (unresolvedLegacy.length > 0) {
      showToast("Resuelva las coberturas legacy ambiguas antes de guardar");
      return;
    }
    if (Object.values(schedule).some((day) =>
      (!!day.mp && day.mp === day.mb) || (!!day.tp && day.tp === day.tb)
    )) {
      showToast("Primaria y respaldo deben ser agentes distintos");
      return;
    }
    const data = Object.entries(schedule).map(([date, day]) => ({
      date,
      morning: [day.mp, day.mb].filter(Boolean),
      afternoon: [day.tp, day.tb].filter(Boolean),
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
    (n, d) => n + [d.mp, d.mb, d.tp, d.tb].filter(Boolean).length,
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
          <h2 className="font-display text-base font-bold text-foreground">Calendario de Guardias</h2>
          <div className="text-xs text-muted-foreground">
            Asigne guardia primaria y respaldo por turno — los cambios se guardan en Supabase
          </div>
        </div>
        <div className="flex items-center gap-2">
          {fullDayDates.length > 0 && (
            <span className="nb-chip">
              {fullDayDates.length} dia(s) con la misma primaria todo el dia
            </span>
          )}
          {dirty && (
            <span className="nb-chip is-accent">
              Sin guardar
            </span>
          )}
          <button
            onClick={handleSave}
            disabled={isPending || !dirty}
            className="inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-primary px-4 py-2 font-display text-xs font-bold text-primary-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-foreground hover:text-background hover:shadow-[var(--shadow-hover)] disabled:opacity-40 disabled:cursor-not-allowed disabled:shadow-none disabled:hover:translate-x-0 disabled:hover:translate-y-0"
          >
            {isPending ? "Guardando..." : "Guardar mes"}
          </button>
        </div>
      </div>

      {/* Controls */}
      {unresolvedLegacy.length > 0 && (
        <div className="mb-4 rounded-[var(--radius-sm)] border-2 border-foreground bg-[var(--amber)] px-4 py-3 text-xs font-bold text-foreground">
          Cobertura legacy ambigua en {unresolvedLegacy.length} turno(s). Vuelva a elegir primaria o respaldo en cada turno marcado antes de guardar.
        </div>
      )}
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
          const fullDay = dayIsFullDay(day);

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

              {/* Ordered primary/backup coverage. */}
              {([[["mp", "mb"], true], [["tp", "tb"], false]] as const).map(([slots, isMorning]) => {
                return (
                  <div key={slots[0]} className={`grid grid-cols-2 gap-1 px-1.5 py-1.5 border-l border-[var(--line-2)] ${
                    unresolvedLegacy.includes(`${date}:${isMorning ? "morning" : "afternoon"}`) ? "bg-[var(--amber)]" : ""
                  }`}>
                    {slots.map((slot, index) => (
                      <label key={slot} className="min-w-0">
                        <span className="block px-1 pb-0.5 font-display text-[9px] font-extrabold uppercase text-muted-foreground">
                          {index === 0 ? "Primaria" : "Respaldo"}
                        </span>
                        <select
                          value={day[slot]}
                          onChange={(e) => updateSlot(date, slot, e.target.value)}
                          className={`w-full px-1.5 py-1.5 rounded-[var(--radius-sm)] text-xs font-bold border-2 border-foreground transition-colors cursor-pointer ${
                            fullDay && index === 0
                              ? "bg-[var(--green)] text-foreground"
                              : day[slot]
                              ? isMorning
                                ? "bg-[var(--accent-fill)] text-foreground"
                                : "bg-[var(--neutral)] text-foreground"
                              : "bg-card text-muted-foreground"
                          } focus:outline-none focus:-translate-x-px focus:-translate-y-px focus:shadow-[var(--shadow-sm)]`}
                        >
                          <option value="">--</option>
                          {agents.map((a) => (
                            <option key={a.agent_id} value={a.agent_id} disabled={a.agent_id === day[slots[index === 0 ? 1 : 0]]}>
                              {a.name}
                            </option>
                          ))}
                        </select>
                      </label>
                    ))}
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
              <div className="font-mono text-2xl font-bold" style={{ color: agentColors[a.agent_id] }}>
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
