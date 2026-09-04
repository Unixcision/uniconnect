import { notFound } from "next/navigation";

// Do not present the upstream operator's terms as UniConnect's agreement.
export default function TermsOfServicePage(): never {
  notFound();
}
