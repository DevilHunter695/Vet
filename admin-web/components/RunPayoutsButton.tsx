"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

/// G7 + Q: "payout run" — the ops console surface for the plan's §6.5
/// weekly payout job, callable on demand rather than only from a cron.
export default function RunPayoutsButton() {
  const supabase = createClient();
  const router = useRouter();
  const [isRunning, setIsRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runPayouts() {
    setIsRunning(true);
    setError(null);
    const today = new Date();
    const periodStart = new Date(today);
    periodStart.setDate(today.getDate() - 7);

    const { error } = await supabase.rpc("run_weekly_payouts", {
      p_period_start: periodStart.toISOString().slice(0, 10),
      p_period_end: today.toISOString().slice(0, 10),
    });
    setIsRunning(false);
    if (error) {
      setError(error.message);
      return;
    }
    router.refresh();
  }

  return (
    <div>
      <button onClick={runPayouts} disabled={isRunning}>
        {isRunning ? "Running…" : "Run payouts now"}
      </button>
      {error && <p style={{ color: "#c0392b", fontSize: 13, marginTop: 8 }}>{error}</p>}
    </div>
  );
}
