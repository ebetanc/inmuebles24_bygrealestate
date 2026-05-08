import { useState } from "react";

const nodes = [
  {
    id: "trigger",
    label: "⏰ Schedule Trigger",
    subtitle: "Cron: 8AM · 2PM · 8PM",
    detail: "Runs 3 times daily using cron expression. Initiates the entire scraping pipeline. Timezone: America/Mexico_City (UTC-6).",
    x: 80, y: 44, w: 200, h: 88,
    color: "#7c3aed", border: "#a78bfa", glow: "#7c3aed"
  },
  {
    id: "config",
    label: "⚙️ Run Config",
    subtitle: "Generate URLs + Run ID",
    detail: "Creates unique run ID for tracking, generates 3 page URLs to scrape: pages 1-3 of inmuebles24.com Ciudad de México listings.",
    x: 340, y: 44, w: 200, h: 88,
    color: "#6366f1", border: "#818cf8", glow: "#6366f1"
  },
  {
    id: "firecrawl",
    label: "🔥 Firecrawl API",
    subtitle: "Scrape 3 Pages → Markdown",
    detail: "POST /v1/scrape to Firecrawl. Scrapes each page with JS rendering (5s wait), returns clean markdown. Retry: 3 attempts, 5s delay. Outputs raw markdown per page.",
    x: 600, y: 44, w: 220, h: 88,
    color: "#ea580c", border: "#fb923c", glow: "#ea580c"
  },
  {
    id: "parse",
    label: "🤖 Parse & Extract",
    subtitle: "Markdown → Structured Listings",
    detail: "Multi-strategy regex parser extracts: title, price, location, URL, property type, bedrooms, bathrooms, area, images. Generates SHA-based listing_hash for each. Deduplicates within batch.",
    x: 880, y: 44, w: 220, h: 88,
    color: "#0891b2", border: "#22d3ee", glow: "#0891b2"
  },
  {
    id: "supabase_get",
    label: "💾 Supabase: Get Existing",
    subtitle: "Fetch known listing hashes",
    detail: "Queries the 'listings' table for all active listing_hash values. Returns a Set used for O(1) lookup during comparison. Uses service_role key to bypass RLS.",
    x: 80, y: 200, w: 220, h: 88,
    color: "#059669", border: "#34d399", glow: "#059669"
  },
  {
    id: "compare",
    label: "🔍 Compare & Filter",
    subtitle: "New vs. Known → Only NEW",
    detail: "Compares scraped listing hashes against Supabase records. Filters to only keep listings NOT in the database. Outputs: newListings array, newCount, duplicateCount.",
    x: 360, y: 200, w: 220, h: 88,
    color: "#2563eb", border: "#60a5fa", glow: "#2563eb"
  },
  {
    id: "if_new",
    label: "❓ IF: New Found?",
    subtitle: "newCount > 0 → Branch",
    detail: "Decision node. YES branch: new listings exist → proceed to insert and notify. NO branch: all duplicates → log run and end quietly.",
    x: 640, y: 200, w: 180, h: 88,
    color: "#d97706", border: "#fbbf24", glow: "#d97706"
  },
  {
    id: "insert",
    label: "💾 Supabase: Insert",
    subtitle: "Store new listings in DB",
    detail: "Inserts each new listing as a row in the 'listings' table with all parsed fields: title, price, location, URL, features, hash, timestamps. Marks notified=false initially.",
    x: 880, y: 160, w: 220, h: 80,
    color: "#059669", border: "#34d399", glow: "#059669"
  },
  {
    id: "format",
    label: "📝 Format Message",
    subtitle: "Telegram HTML + Email text",
    detail: "Generates rich Telegram message with HTML formatting: property title, price, location, features, direct links. Also creates plain-text email version. Shows up to 10 listings in Telegram.",
    x: 880, y: 272, w: 220, h: 80,
    color: "#7c3aed", border: "#a78bfa", glow: "#7c3aed"
  },
  {
    id: "telegram",
    label: "📢 Telegram Bot",
    subtitle: "Send notification",
    detail: "Sends formatted HTML message via Telegram Bot API. Includes: property details, prices in MXN/USD, locations, clickable links to listings. Supports groups and channels.",
    x: 640, y: 356, w: 200, h: 80,
    color: "#0ea5e9", border: "#38bdf8", glow: "#0ea5e9"
  },
  {
    id: "log_success",
    label: "📊 Log: Success",
    subtitle: "Record run stats to DB",
    detail: "Inserts row into 'scrape_logs' table: run_id, timestamps, total_scraped, new_listings, duplicates, pages_scraped, notifications_sent. Complete audit trail.",
    x: 880, y: 388, w: 220, h: 80,
    color: "#059669", border: "#34d399", glow: "#059669"
  },
  {
    id: "log_nochange",
    label: "✅ Log: No Changes",
    subtitle: "Record empty run",
    detail: "NO branch: logs that the scrape found no new listings. Keeps audit trail complete. Workflow ends here when everything was duplicates.",
    x: 640, y: 480, w: 200, h: 72,
    color: "#525252", border: "#737373", glow: "#525252"
  }
];

const connections = [
  { from: "trigger", to: "config" },
  { from: "config", to: "firecrawl" },
  { from: "firecrawl", to: "parse" },
  { from: "parse", to: "supabase_get", curved: true },
  { from: "supabase_get", to: "compare" },
  { from: "compare", to: "if_new" },
  { from: "if_new", to: "insert", label: "YES" },
  { from: "insert", to: "format" },
  { from: "format", to: "telegram", curved: true },
  { from: "format", to: "log_success" },
  { from: "if_new", to: "log_nochange", label: "NO" },
];

function getNodeCenter(node) {
  return { x: node.x + node.w / 2, y: node.y + node.h / 2 };
}

function ConnectionLine({ from, to, label, curved }) {
  const a = getNodeCenter(from);
  const b = getNodeCenter(to);
  const dx = b.x - a.x;
  const dy = b.y - a.y;

  let path;
  if (curved) {
    const cx = a.x + dx * 0.1;
    const cy = a.y + dy * 0.9;
    path = `M ${a.x} ${a.y} Q ${cx} ${cy} ${b.x} ${b.y}`;
  } else {
    const mx = a.x + dx * 0.5;
    path = `M ${a.x} ${a.y} C ${mx} ${a.y} ${mx} ${b.y} ${b.x} ${b.y}`;
  }

  const labelX = a.x + dx * 0.5;
  const labelY = a.y + dy * 0.5 - 8;

  return (
    <g>
      <path d={path} stroke="#475569" strokeWidth="2" fill="none" strokeDasharray={label === "NO" ? "6 4" : "none"} />
      <circle cx={b.x} cy={b.y} r="4" fill="#475569" />
      {label && (
        <g>
          <rect x={labelX - 16} y={labelY - 10} width="32" height="20" rx="4" fill={label === "YES" ? "#059669" : "#dc2626"} />
          <text x={labelX} y={labelY + 3} textAnchor="middle" fill="white" fontSize="10" fontWeight="700" fontFamily="monospace">{label}</text>
        </g>
      )}
    </g>
  );
}

export default function WorkflowDiagram() {
  const [selected, setSelected] = useState(null);
  const [hoveredNode, setHoveredNode] = useState(null);
  const selectedNode = nodes.find(n => n.id === selected);

  return (
    <div style={{ background: "#0a0a0f", minHeight: "100vh", fontFamily: "'JetBrains Mono', 'SF Mono', 'Fira Code', monospace" }}>
      <div style={{ maxWidth: 1200, margin: "0 auto", padding: "24px 16px" }}>
        {/* Header */}
        <div style={{ marginBottom: 24, borderBottom: "1px solid #1e293b", paddingBottom: 20 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 8 }}>
            <span style={{ fontSize: 28 }}>🏠</span>
            <h1 style={{ color: "#f1f5f9", fontSize: 22, fontWeight: 700, margin: 0, letterSpacing: "-0.5px" }}>
              Inmuebles24 CDMX — n8n Workflow Architecture
            </h1>
          </div>
          <p style={{ color: "#64748b", fontSize: 12, margin: 0, lineHeight: 1.6 }}>
            Real estate scraper → Supabase storage → Deduplication → Telegram notifications · Click any node for details
          </p>
        </div>

        {/* Diagram */}
        <div style={{
          background: "#0f1117",
          border: "1px solid #1e293b",
          borderRadius: 12,
          padding: 20,
          position: "relative",
          overflow: "auto"
        }}>
          <svg width="1160" height="580" style={{ display: "block" }}>
            <defs>
              {nodes.map(n => (
                <filter key={`glow-${n.id}`} id={`glow-${n.id}`}>
                  <feGaussianBlur stdDeviation="6" result="blur" />
                  <feFlood floodColor={n.glow} floodOpacity="0.3" />
                  <feComposite in2="blur" operator="in" />
                  <feMerge>
                    <feMergeNode />
                    <feMergeNode in="SourceGraphic" />
                  </feMerge>
                </filter>
              ))}
            </defs>

            {/* Grid dots */}
            {Array.from({ length: 30 }).map((_, i) =>
              Array.from({ length: 15 }).map((_, j) => (
                <circle key={`dot-${i}-${j}`} cx={i * 40 + 20} cy={j * 40 + 20} r="0.8" fill="#1e293b" />
              ))
            )}

            {/* Connections */}
            {connections.map((conn, i) => {
              const fromNode = nodes.find(n => n.id === conn.from);
              const toNode = nodes.find(n => n.id === conn.to);
              return <ConnectionLine key={i} from={fromNode} to={toNode} label={conn.label} curved={conn.curved} />;
            })}

            {/* Nodes */}
            {nodes.map(node => {
              const isSelected = selected === node.id;
              const isHovered = hoveredNode === node.id;
              return (
                <g
                  key={node.id}
                  onClick={() => setSelected(isSelected ? null : node.id)}
                  onMouseEnter={() => setHoveredNode(node.id)}
                  onMouseLeave={() => setHoveredNode(null)}
                  style={{ cursor: "pointer" }}
                  filter={isSelected || isHovered ? `url(#glow-${node.id})` : undefined}
                >
                  <rect
                    x={node.x} y={node.y}
                    width={node.w} height={node.h}
                    rx="10"
                    fill={isSelected ? `${node.color}30` : "#131620"}
                    stroke={isSelected || isHovered ? node.border : "#1e293b"}
                    strokeWidth={isSelected ? 2.5 : isHovered ? 2 : 1}
                  />
                  <rect
                    x={node.x} y={node.y}
                    width={node.w} height="3"
                    rx="0"
                    fill={node.color}
                    clipPath={`inset(0 0 0 0 round 10px 10px 0 0)`}
                  />
                  <text
                    x={node.x + node.w / 2} y={node.y + 32}
                    textAnchor="middle"
                    fill="#e2e8f0"
                    fontSize="12.5"
                    fontWeight="700"
                    fontFamily="'JetBrains Mono', monospace"
                  >
                    {node.label}
                  </text>
                  <text
                    x={node.x + node.w / 2} y={node.y + 52}
                    textAnchor="middle"
                    fill="#64748b"
                    fontSize="10"
                    fontFamily="'JetBrains Mono', monospace"
                  >
                    {node.subtitle}
                  </text>
                </g>
              );
            })}

            {/* Phase labels */}
            <text x="30" y="30" fill="#334155" fontSize="10" fontWeight="600" fontFamily="monospace">PHASE 1: SCRAPE</text>
            <text x="30" y="186" fill="#334155" fontSize="10" fontWeight="600" fontFamily="monospace">PHASE 2: DEDUPLICATE</text>
            <text x="830" y="150" fill="#334155" fontSize="10" fontWeight="600" fontFamily="monospace">PHASE 3: STORE</text>
            <text x="600" y="346" fill="#334155" fontSize="10" fontWeight="600" fontFamily="monospace">PHASE 4: NOTIFY</text>
          </svg>
        </div>

        {/* Detail Panel */}
        <div style={{
          marginTop: 16,
          background: selectedNode ? `${selectedNode.color}08` : "#0f1117",
          border: `1px solid ${selectedNode ? selectedNode.border + "40" : "#1e293b"}`,
          borderRadius: 10,
          padding: "16px 20px",
          minHeight: 60,
          transition: "all 0.2s ease"
        }}>
          {selectedNode ? (
            <div>
              <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
                <div style={{
                  width: 10, height: 10, borderRadius: "50%",
                  background: selectedNode.color,
                  boxShadow: `0 0 8px ${selectedNode.glow}`
                }} />
                <span style={{ color: "#f1f5f9", fontSize: 14, fontWeight: 700 }}>{selectedNode.label}</span>
                <span style={{ color: "#475569", fontSize: 11 }}>·</span>
                <span style={{ color: "#64748b", fontSize: 11 }}>{selectedNode.subtitle}</span>
              </div>
              <p style={{ color: "#94a3b8", fontSize: 12, lineHeight: 1.7, margin: 0 }}>
                {selectedNode.detail}
              </p>
            </div>
          ) : (
            <p style={{ color: "#475569", fontSize: 12, margin: 0 }}>
              ← Click any node above to see its configuration details and purpose
            </p>
          )}
        </div>

        {/* Tech Stack */}
        <div style={{ marginTop: 16, display: "flex", gap: 12, flexWrap: "wrap" }}>
          {[
            { label: "n8n", desc: "Workflow Engine", color: "#ea580c" },
            { label: "Firecrawl", desc: "Web Scraping API", color: "#dc2626" },
            { label: "Supabase", desc: "PostgreSQL + API", color: "#059669" },
            { label: "Telegram", desc: "Notifications", color: "#0ea5e9" },
            { label: "Cron", desc: "3x/day Schedule", color: "#7c3aed" }
          ].map(tech => (
            <div key={tech.label} style={{
              background: "#0f1117",
              border: "1px solid #1e293b",
              borderRadius: 8,
              padding: "8px 14px",
              display: "flex",
              alignItems: "center",
              gap: 8
            }}>
              <div style={{ width: 6, height: 6, borderRadius: "50%", background: tech.color }} />
              <span style={{ color: "#e2e8f0", fontSize: 11, fontWeight: 600 }}>{tech.label}</span>
              <span style={{ color: "#475569", fontSize: 10 }}>{tech.desc}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
