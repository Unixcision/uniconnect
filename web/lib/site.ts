const fallbackSiteURL = "https://uniconnect.invalid";

/**
 * Public origin used for canonical metadata.
 *
 * The reserved `.invalid` fallback prevents a local or unconfigured deployment
 * from advertising the upstream cmux website as its own. Production must set
 * `NEXT_PUBLIC_UNICONNECT_SITE_URL` to an HTTPS origin owned by UniConnect.
 */
export const SITE_URL = resolveSiteURL(
  process.env.NEXT_PUBLIC_UNICONNECT_SITE_URL,
);

export function resolveSiteURL(value: string | undefined): string {
  const candidate = value?.trim();
  if (!candidate) return fallbackSiteURL;

  try {
    const parsed = new URL(candidate);
    if (
      parsed.protocol !== "https:" ||
      parsed.username.length > 0 ||
      parsed.password.length > 0
    ) {
      return fallbackSiteURL;
    }
    return parsed.origin;
  } catch {
    return fallbackSiteURL;
  }
}
