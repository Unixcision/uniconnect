import { notFound } from "next/navigation";

// The upstream policy named a different company, domain, data controller, and
// telemetry configuration. Keep this route unavailable until the UniConnect
// operator publishes reviewed owner-specific legal text.
export default function PrivacyPolicyPage(): never {
  notFound();
}
