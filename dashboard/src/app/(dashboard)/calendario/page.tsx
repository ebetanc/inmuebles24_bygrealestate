import { getGuardSchedule, getAgents } from "@/lib/queries";

export const dynamic = "force-dynamic";

const dayNames = ["Domingo", "Lunes", "Martes", "Miercoles", "Jueves", "Viernes", "Sabado"];
const agentColors = ["#3B82F6", "#8B5CF6", "#F59E0B", "#EC4899", "#22C55E", "#06B6D4", "#EF4444"];

export default async function CalendarioPage() {
  const [schedule, agents] = await Promise.all([
    getGuardSchedule(),
    getAgents(),
  ]);

  const agentMap = new Map(agents.map((a, i) => [a.agent_id, { name: a.name, color: agentColors[i % agentColors.length] }]));
  const today = new Date().toISOString().split("T")[0];

  // Group by date
  const byDate = new Map<string, typeof schedule>();
  for (const shift of schedule) {
    const date = shift.schedule_date;
    if (!byDate.has(date)) byDate.set(date, []);
    byDate.get(date)!.push(shift);
  }

  const dates = Array.from(byDate.keys()).sort();

  return (
    <div>
      <div className="mb-5">
        <h2 className="text-base font-bold text-[#0F172A]">Calendario de Guardias</h2>
        <div className="text-xs text-[#94A3B8]">Proximos 7 dias — sincronizado con Google Sheets</div>
      </div>

      {dates.length > 0 ? (
        <div className="rounded-xl border border-[#E2E8F0] overflow-hidden">
          {/* Header */}
          <div className="grid grid-cols-[140px_1fr_1fr] border-b border-[#E2E8F0]">
            <div className="bg-[#F8FAFC] px-4 py-3.5 text-[11px] font-bold uppercase tracking-wide text-[#64748B]">
              Dia
            </div>
            <div className="bg-[#F8FAFC] px-4 py-3.5 text-[11px] font-bold uppercase tracking-wide text-[#64748B] border-l border-[#E2E8F0]">
              Manana (8:00 — 14:00)
            </div>
            <div className="bg-[#F8FAFC] px-4 py-3.5 text-[11px] font-bold uppercase tracking-wide text-[#64748B] border-l border-[#E2E8F0]">
              Tarde (14:00 — 21:00)
            </div>
          </div>

          {/* Rows */}
          {dates.map((date) => {
            const shifts = byDate.get(date)!;
            const d = new Date(date + "T12:00:00");
            const isToday = date === today;
            const morningShifts = shifts.filter((s) => s.shift === "morning");
            const afternoonShifts = shifts.filter((s) => s.shift === "afternoon");

            return (
              <div
                key={date}
                className={`grid grid-cols-[140px_1fr_1fr] border-b border-[#F1F5F9] last:border-b-0 ${
                  isToday ? "bg-[#EFF6FF]" : ""
                }`}
              >
                {/* Day cell */}
                <div className="flex items-center gap-2 border-r border-[#F1F5F9] bg-[#FAFBFC] px-4 py-3.5 text-[13px] font-bold text-[#0F172A]">
                  <span>{dayNames[d.getDay()]}</span>
                  {isToday && (
                    <span className="rounded bg-[#1D4ED8] px-1.5 py-0.5 text-[10px] font-bold text-white">
                      Hoy
                    </span>
                  )}
                </div>

                {/* Morning */}
                <div className="flex flex-wrap items-center gap-2 border-r border-[#F1F5F9] px-4 py-3.5">
                  {morningShifts.map((s) => {
                    const agent = agentMap.get(s.agent_id);
                    return (
                      <span
                        key={s.agent_id}
                        className="inline-flex items-center gap-1.5 rounded-md bg-[#F1F5F9] px-2.5 py-1 text-xs font-semibold text-[#334155]"
                      >
                        <span
                          className="h-2 w-2 rounded-full shrink-0"
                          style={{ background: agent?.color || "#94A3B8" }}
                        />
                        {agent?.name || s.agent_id}
                      </span>
                    );
                  })}
                  {morningShifts.length === 0 && (
                    <span className="text-xs text-[#CBD5E1]">—</span>
                  )}
                </div>

                {/* Afternoon */}
                <div className="flex flex-wrap items-center gap-2 px-4 py-3.5">
                  {afternoonShifts.map((s) => {
                    const agent = agentMap.get(s.agent_id);
                    return (
                      <span
                        key={s.agent_id}
                        className="inline-flex items-center gap-1.5 rounded-md bg-[#F1F5F9] px-2.5 py-1 text-xs font-semibold text-[#334155]"
                      >
                        <span
                          className="h-2 w-2 rounded-full shrink-0"
                          style={{ background: agent?.color || "#94A3B8" }}
                        />
                        {agent?.name || s.agent_id}
                      </span>
                    );
                  })}
                  {afternoonShifts.length === 0 && (
                    <span className="text-xs text-[#CBD5E1]">—</span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="rounded-xl border border-[#E2E8F0] bg-white p-12 text-center text-sm text-[#94A3B8]">
          No hay guardias programadas. Sincroniza desde Google Sheets con WF6.
        </div>
      )}
    </div>
  );
}
