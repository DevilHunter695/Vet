"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setIsLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setIsLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    router.push("/");
    router.refresh();
  }

  return (
    <div className="container" style={{ maxWidth: 380, paddingTop: 80 }}>
      <h1>VetCircuit Partner</h1>
      <p className="muted">Sign in to manage your circuit and visits.</p>
      <form onSubmit={handleSubmit} style={{ display: "grid", gap: 12, marginTop: 20 }}>
        <input
          type="email"
          placeholder="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <input
          type="password"
          placeholder="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />
        {error && <p style={{ color: "#c0392b", fontSize: 13 }}>{error}</p>}
        <button type="submit" disabled={isLoading}>
          {isLoading ? "Signing in…" : "Sign in"}
        </button>
      </form>
      <p className="muted" style={{ marginTop: 16 }}>
        New partner? Onboarding and verification is handled manually — contact the VetCircuit team.
      </p>
    </div>
  );
}
