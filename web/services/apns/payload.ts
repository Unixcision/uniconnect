// Pure, dependency-free helpers for building APNs requests. Kept separate from
// the http2/crypto sender so they can be unit-tested in isolation.

export type ApnsEnvironment = "sandbox" | "production";

export const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

/** APNs host for a stored token's environment (defaults to production). */
export function apnsHostForEnvironment(environment: string): string {
  return environment === "sandbox" ? APNS_HOSTS.sandbox : APNS_HOSTS.production;
}

export interface ApnsNotificationInput {
  readonly title: string;
  readonly subtitle?: string | null;
  readonly body: string;
  readonly workspaceId?: string | null;
  readonly surfaceId?: string | null;
  /** The sending Mac's BCP-47 locale, used only for generic hidden content. */
  readonly locale?: string | null;
  /** When true, replace real terminal text with a localized generic fallback. */
  readonly hideContent?: boolean;
}

const HIDDEN_NOTIFICATION_BODY = {
  ar: "يحتاج وكيل إلى انتباهك",
  bs: "Agent treba vašu pažnju",
  da: "En agent har brug for din opmærksomhed",
  de: "Ein Agent benötigt deine Aufmerksamkeit",
  en: "An agent needs your attention",
  es: "Un agente necesita tu atención",
  fr: "Un agent a besoin de votre attention",
  it: "Un agente richiede la tua attenzione",
  ja: "エージェントが注意を必要としています",
  km: "ភ្នាក់ងារត្រូវការការយកចិត្តទុកដាក់របស់អ្នក",
  ko: "에이전트가 사용자의 주의를 필요로 합니다",
  nb: "En agent trenger oppmerksomheten din",
  pl: "Agent wymaga Twojej uwagi",
  "pt-BR": "Um agente precisa da sua atenção",
  ru: "Агент требует вашего внимания",
  th: "เอเจนต์ต้องการความสนใจจากคุณ",
  tr: "Bir ajan dikkatinizi bekliyor",
  uk: "Агент потребує вашої уваги",
  "zh-Hans": "某个智能体需要你的关注",
  "zh-Hant": "某個代理程式需要你的注意",
} as const;

type HiddenNotificationLocale = keyof typeof HIDDEN_NOTIFICATION_BODY;

/** Resolve app-supported locale variants without reflecting arbitrary input into APNs. */
export function hiddenNotificationBody(locale: string | null | undefined): string {
  const normalized = (locale ?? "").trim().replaceAll("_", "-");
  const lower = normalized.toLowerCase();

  let key: HiddenNotificationLocale;
  if (/^zh-(hant|tw|hk|mo)(-|$)/.test(lower)) key = "zh-Hant";
  else if (/^zh-(hans|cn|sg)(-|$)/.test(lower)) key = "zh-Hans";
  else if (/^pt(-|$)/.test(lower)) key = "pt-BR";
  else if (/^(nb|no)(-|$)/.test(lower)) key = "nb";
  else {
    const language = lower.split("-", 1)[0] as HiddenNotificationLocale;
    key = Object.hasOwn(HIDDEN_NOTIFICATION_BODY, language) ? language : "en";
  }
  return HIDDEN_NOTIFICATION_BODY[key];
}

/**
 * Build the APNs JSON payload. Adds `uniconnect.workspaceId`/`uniconnect.surfaceId` custom
 * keys so a tapped notification can deep-link to the right terminal, and marks
 * the alert time-sensitive (the app holds that entitlement).
 */
export function buildApnsPayload(input: ApnsNotificationInput): Record<string, unknown> {
  const hidden = input.hideContent === true;
  const title = hidden ? "UniConnect" : input.title.trim() || "UniConnect";
  const body = hidden ? hiddenNotificationBody(input.locale) : input.body;
  const subtitle = hidden ? undefined : input.subtitle?.trim() || undefined;

  const alert: Record<string, string> = { title };
  if (subtitle) alert.subtitle = subtitle;
  if (body) alert.body = body;

  const aps: Record<string, unknown> = {
    alert,
    sound: "default",
    "interruption-level": "time-sensitive",
  };

  const uniconnect: Record<string, string> = {};
  if (input.workspaceId) uniconnect.workspaceId = input.workspaceId;
  if (input.surfaceId) uniconnect.surfaceId = input.surfaceId;

  return Object.keys(uniconnect).length > 0 ? { aps, uniconnect } : { aps };
}

/**
 * Whether an APNs response means the token is permanently invalid and should be
 * deleted. 410 (Unregistered, with a timestamp) and the `BadDeviceToken` /
 * `DeviceTokenNotForTopic` / `Unregistered` reasons are terminal; transient
 * failures (timeouts, 5xx, connection errors with status 0) are not pruned.
 */
export function shouldPruneToken(status: number, reason: string | undefined): boolean {
  if (status === 410) return true;
  if (reason === "Unregistered") return true;
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) {
    return true;
  }
  return false;
}
