"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { FeatureFlag } from "@/lib/types";

export default function FlagsTable({ initialFlags }: { initialFlags: FeatureFlag[] }) {
  const supabase = createClient();
  const [flags, setFlags] = useState(initialFlags);
  const [busyName, setBusyName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function toggle(flag: FeatureFlag) {
    setBusyName(flag.name);
    setError(null);
    // Direct write, gated by the "feature_flags admin write" RLS policy —
    // no Edge Function needed since flipping a flag isn't money or a state
    // machine transition, just a config value.
    const { error } = await supabase.from("feature_flags").update({ enabled: !flag.enabled }).eq("name", flag.name);
    setBusyName(null);
    if (error) {
      setError(error.message);
      return;
    }
    setFlags((prev) => prev.map((f) => (f.name === flag.name ? { ...f, enabled: !f.enabled } : f)));
  }

  if (flags.length === 0) {
    return <p className="muted">No feature flags defined.</p>;
  }

  return (
    <div>
      {error && <p style={{ color: "#c0392b", fontSize: 13, marginBottom: 12 }}>{error}</p>}
      {flags.map((flag) => (
        <div key={flag.name} className="card">
          <div className="row">
            <div>
              <strong>{flag.name}</strong>
              {flag.description && <p className="muted" style={{ marginTop: 4 }}>{flag.description}</p>}
            </div>
            <div className="row" style={{ gap: 8 }}>
              <span className={`badge ${flag.enabled ? "verified" : "rejected"}`}>
                {flag.enabled ? "on" : "off"}
              </span>
              <button
                className={flag.enabled ? "danger" : ""}
                onClick={() => toggle(flag)}
                disabled={busyName === flag.name}
              >
                {flag.enabled ? "Turn off" : "Turn on"}
              </button>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
