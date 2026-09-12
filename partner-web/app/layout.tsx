import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "VetCircuit Partner",
  description: "Manage your circuit, visits, and payouts.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
