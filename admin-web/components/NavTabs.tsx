"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/", label: "Overview" },
  { href: "/vets", label: "Vets" },
  { href: "/circuits", label: "Circuits" },
  { href: "/disputes", label: "Disputes" },
  { href: "/payouts", label: "Payouts" },
  { href: "/flags", label: "Flags" },
  { href: "/visits", label: "Visits" },
];

export default function NavTabs() {
  const pathname = usePathname();
  return (
    <nav className="tabs">
      {TABS.map((tab) => (
        <Link key={tab.href} href={tab.href} className={pathname === tab.href ? "active" : ""}>
          {tab.label}
        </Link>
      ))}
    </nav>
  );
}
