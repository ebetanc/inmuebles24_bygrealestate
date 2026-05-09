import { getMonthSchedule, getAgents } from "@/lib/queries";
import CalendarEditor from "./calendar-editor";

export const dynamic = "force-dynamic";

export default async function CalendarioPage({
  searchParams,
}: {
  searchParams: Promise<{ y?: string; m?: string }>;
}) {
  const params = await searchParams;
  const now = new Date();
  const year = params.y ? parseInt(params.y) : now.getFullYear();
  const month = params.m ? parseInt(params.m) : now.getMonth() + 1;

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
