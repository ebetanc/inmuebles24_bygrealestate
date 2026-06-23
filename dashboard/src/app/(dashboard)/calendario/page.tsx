import { getMonthSchedule, getAgents } from "@/lib/queries";
import { mxToday } from "@/lib/datetime";
import CalendarEditor from "./calendar-editor";

export const dynamic = "force-dynamic";

export default async function CalendarioPage({
  searchParams,
}: {
  searchParams: Promise<{ y?: string; m?: string }>;
}) {
  const params = await searchParams;
  // Default to the current CDMX month (not the UTC server month).
  const [mxYear, mxMonth] = mxToday().split("-").map(Number);
  const year = params.y ? parseInt(params.y) : mxYear;
  const month = params.m ? parseInt(params.m) : mxMonth;

  const [schedule, agents] = await Promise.all([
    getMonthSchedule(year, month),
    getAgents(),
  ]);

  return (
    <CalendarEditor
      agents={agents.map((a) => ({ agent_id: a.agent_id, name: a.name }))}
      initialSchedule={schedule}
      initialYear={year}
      initialMonth={month}
    />
  );
}
