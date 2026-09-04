import { locales } from "./routing";
import { SITE_URL } from "@/lib/site";

/**
 * Build the full alternates object (canonical + hreflang languages)
 * for a given locale and path. Use in every generateMetadata that
 * sets alternates so child metadata doesn't wipe parent hreflang.
 */
export function buildAlternates(locale: string, path: string) {
  const languages: Record<string, string> = {};
  for (const loc of locales) {
    languages[loc] =
      loc === "en" ? `${SITE_URL}${path}` : `${SITE_URL}/${loc}${path}`;
  }
  languages["x-default"] = `${SITE_URL}${path}`;

  const canonical =
    locale === "en" ? `${SITE_URL}${path}` : `${SITE_URL}/${locale}${path}`;

  return { canonical, languages };
}
