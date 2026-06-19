import { getAllAgents, getAgentAliases, getAgentStats } from "@/lib/queries";
import AgentManager from "./agent-manager";

export const dynamic = "force-dynamic";

export default async function AgentesPage() {
  const [agents, aliases] = await Promise.all([getAllAgents(), getAgentAliases()]);

  const stats: Record<string, number> = {};
  await Promise.all(
    agents.map(async (a) => {
      const s = await getAgentStats(a.agent_id);
      stats[a.agent_id] = s.leadsThisWeek;
    })
  );

  return <AgentManager agents={agents} aliases={aliases} stats={stats} />;
}
