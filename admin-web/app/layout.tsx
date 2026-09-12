import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "VetCircuit Admin",
  description: "Onboard vets, monitor circuits, handle disputes.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
