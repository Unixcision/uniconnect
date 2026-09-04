import { notFound } from "next/navigation";

// Do not present the upstream operator's EULA as UniConnect's agreement.
export default function EulaPage(): never {
  notFound();
}
