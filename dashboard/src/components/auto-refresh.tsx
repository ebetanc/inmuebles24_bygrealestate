"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, useCallback } from "react";

const INTERVAL_MS = 30_000;

export function AutoRefresh() {
  const router = useRouter();
  const [lastRefresh, setLastRefresh] = useState<Date>(new Date());
  const [secondsAgo, setSecondsAgo] = useState(0);

  const refresh = useCallback(() => {
    router.refresh();
    setLastRefresh(new Date());
  }, [router]);

  useEffect(() => {
    const interval = setInterval(refresh, INTERVAL_MS);
    return () => clearInterval(interval);
  }, [refresh]);

  useEffect(() => {
    const tick = setInterval(() => {
      setSecondsAgo(Math.floor((Date.now() - lastRefresh.getTime()) / 1000));
    }, 1000);
    return () => clearInterval(tick);
  }, [lastRefresh]);

  return (
    <button
      onClick={refresh}
      className="flex items-center gap-1.5 rounded-[var(--radius-sm)] border-2 border-foreground bg-card px-3 py-1.5 font-mono text-[12px] font-semibold text-foreground shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background] duration-100 hover:-translate-x-px hover:-translate-y-px hover:bg-accent hover:shadow-[var(--shadow-hover)] active:translate-x-0 active:translate-y-0 active:shadow-[var(--shadow-sm)]"
      title="Actualizar datos"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        strokeWidth={2}
        stroke="currentColor"
        className="h-3.5 w-3.5"
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182M2.985 19.644l3.181-3.18"
        />
      </svg>
      <span className="tabular-nums">{secondsAgo}s</span>
    </button>
  );
}
