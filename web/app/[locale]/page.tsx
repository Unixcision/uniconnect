import { useTranslations } from "next-intl";
import { FadeImage } from "./components/fade-image";
import Balancer from "react-wrap-balancer";
import landingImage from "./assets/landing-image.png";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { GitHubButton } from "./components/github-button";
import { SiteHeader } from "./components/site-header";
import { BrandLogoLink } from "./components/brand-logo-link";
import { Link } from "../../i18n/navigation";

export default function Home() {
  return <HomeContent />;
}

function HomeContent() {
  const t = useTranslations("home");
  const tc = useTranslations("common");
  const linkClass =
    "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10" data-dev="header">
          <BrandLogoLink className="shrink-0">
            <img
              src="/logo.png"
              alt="UniConnect icon"
              width={48}
              height={48}
              className="rounded-xl"
            />
          </BrandLogoLink>
          <h1 className="text-2xl font-semibold tracking-tight">UniConnect</h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          <span className="sr-only">
            {t("taglinePrefix")}
            {t("typingCodingAgents")}, {t("typingMultitasking")}
          </span>
          <span aria-hidden="true">
            {t("taglinePrefix")}
            <TypingTagline />
          </span>
        </p>
        <p
          className="text-base text-muted"
          data-dev="subtitle"
          style={{ lineHeight: 1.5 }}
        >
          <Balancer>
            {t.rich("subtitle", {
              cliLink: (chunks) => (
                <Link href="/docs/api" className={linkClass}>
                  {chunks}
                </Link>
              ),
            })}
          </Balancer>
        </p>

        {/* Download */}
        <div
          className="flex flex-wrap items-center gap-3"
          data-dev="download"
          style={{ marginTop: 21, marginBottom: 16 }}
        >
          <DownloadButton location="hero" />
          <GitHubButton />
        </div>

        {/* Features */}
        <section
          data-dev="features"
          style={{ paddingTop: 12, paddingBottom: 15 }}
        >
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("features")}
          </h2>
          <ul
            className="space-y-3 text-[15px]"
            data-dev="features-ul"
            style={{ lineHeight: 1.275 }}
          >
            {(
              [
                ["verticalTabs", "verticalTabsDesc"],
                ["notificationRings", "notificationRingsDesc"],
                ["inAppBrowser", "inAppBrowserDesc"],
                ["splitPanes", "splitPanesDesc"],
                ["scriptable", "scriptableDesc"],
                ["gpuAccelerated", "gpuAcceleratedDesc"],
                ["lightweight", "lightweightDesc"],
              ] as const
            ).map(([title, desc]) => (
              <li key={title} className="flex gap-3">
                <span className="text-muted shrink-0">-</span>
                <span>
                  <strong className="font-medium">
                    {t(`feature.${title}`)}
                  </strong>
                  <span className="text-muted">{t(`feature.${desc}`)}</span>
                </span>
              </li>
            ))}
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">
                  {t("feature.keyboardShortcuts")}
                </strong>
                <span className="text-muted">
                  {t.rich("feature.keyboardShortcutsDesc", {
                    link: (chunks) => (
                      <Link
                        href="/docs/keyboard-shortcuts"
                        className={linkClass}
                      >
                        {chunks}
                      </Link>
                    ),
                  })}
                </span>
              </span>
            </li>
          </ul>
        </section>

        {/* Screenshot */}
        <div
          data-dev="screenshot"
          className="mb-12 -mx-6 sm:-mx-24 md:-mx-40 lg:-mx-72 xl:-mx-96"
        >
          <FadeImage
            src={landingImage}
            alt="UniConnect terminal app screenshot"
            priority
            className="w-full rounded-xl"
          />
        </div>

        {/* FAQ */}
        <div data-dev="faq-top-spacer" style={{ height: 0 }} />
        <section data-dev="faq" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("faq")}
          </h2>
          <div
            className="space-y-5 text-[15px]"
            style={{ lineHeight: 1.5 }}
          >
            <div>
              <p className="font-medium mb-1">{t("faqGhosttyQ")}</p>
              <p className="text-muted">
                {t.rich("faqGhosttyA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/ghostty-org/ghostty"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqPlatformQ")}</p>
              <p className="text-muted">{t("faqPlatformA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqAgentsQ")}</p>
              <p className="text-muted">{t("faqAgentsA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqNotificationsQ")}</p>
              <p className="text-muted">
                {t.rich("faqNotificationsA", {
                  cliLink: (chunks) => (
                    <Link href="/docs/notifications#cli-usage" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  hooksLink: (chunks) => (
                    <Link href="/docs/notifications#integration-examples" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqShortcutsQ")}</p>
              <p className="text-muted">
                {t.rich("faqShortcutsA", {
                  configPath: (chunks) => (
                    <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
                      {chunks}
                    </code>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqTmuxQ")}</p>
              <p className="text-muted">{t("faqTmuxA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqFreeQ")}</p>
              <p className="text-muted">
                {t.rich("faqFreeA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/Unixcision/uniconnect"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
          </div>
        </section>

        {/* Bottom CTA */}
        <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
          <DownloadButton location="bottom" />
          <GitHubButton />
        </div>
        <div className="flex justify-center gap-4 mt-6">
          <Link
            href="/docs"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
          >
            {tc("readTheDocs")}
          </Link>
          <Link
            href="/docs/changelog"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
          >
            {tc("viewChangelog")}
          </Link>
        </div>
      </main>
    </div>
  );
}
