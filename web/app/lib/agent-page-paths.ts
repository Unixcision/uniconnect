import { locales } from "../../i18n/routing";

export type AgentPageFormat = "md" | "txt";

export type AgentPageVariant =
  | {
      kind: "page";
      format: AgentPageFormat;
      requestedPath: string;
      canonicalPath: string;
    }
  | {
      kind: "llms";
      requestedPath: string;
    };

const extensionPattern = /\.(md|txt)$/i;
const reservedTextRoutes = new Set(["/robots.txt"]);
const blockedPrefixes = [
  "/api",
  "/_next",
  "/_vercel",
  "/agent-page-variant",
  "/handler",
];
export const agentReadablePages = [
  { path: "/", title: "Home" },
  { path: "/blog", title: "Blog" },
  { path: "/blog/cmux-history", title: "UniConnect history" },
  { path: "/blog/cmux-finder", title: "Introducing UniConnect Finder" },
  { path: "/blog/cmux-vault", title: "UniConnect Vault" },
  { path: "/blog/passkey-auth", title: "Passkey auth in the UniConnect browser" },
  { path: "/blog/task-manager", title: "Task Manager in UniConnect" },
  { path: "/blog/markdown-viewer", title: "A better markdown viewer in UniConnect" },
  { path: "/blog/unread-shortcuts", title: "Unread workspace shortcuts in UniConnect" },
  { path: "/blog/session-restore", title: "Session restore in UniConnect" },
  { path: "/blog/cmux-ssh", title: "UniConnect SSH" },
  {
    path: "/blog/cmux-claude-teams",
    title: "Claude Code teammate agents as native UniConnect panes",
  },
  {
    path: "/blog/cmux-omo",
    title: "oh-my-openagent subagents as native UniConnect panes",
  },
  { path: "/blog/cmd-shift-u", title: "Cmd+Shift+U" },
  { path: "/docs", title: "Docs" },
  { path: "/docs/getting-started", title: "Getting Started" },
  { path: "/docs/concepts", title: "Concepts" },
  { path: "/docs/configuration", title: "Configuration" },
  { path: "/docs/textbox", title: "TextBox" },
  { path: "/docs/custom-commands", title: "Custom Commands" },
  { path: "/docs/dock", title: "Dock" },
  { path: "/docs/keyboard-shortcuts", title: "Keyboard Shortcuts" },
  { path: "/docs/api", title: "CLI Reference" },
  { path: "/docs/browser-automation", title: "Browser Automation" },
  { path: "/docs/skills", title: "Skills" },
  { path: "/docs/notifications", title: "Notifications" },
  { path: "/docs/ssh", title: "SSH" },
  {
    path: "/docs/agent-integrations/claude-code-teams",
    title: "Claude Code Teams",
  },
  {
    path: "/docs/agent-integrations/oh-my-opencode",
    title: "oh-my-opencode",
  },
  {
    path: "/docs/agent-integrations/oh-my-codex",
    title: "oh-my-codex",
  },
  {
    path: "/docs/agent-integrations/oh-my-claudecode",
    title: "oh-my-claudecode",
  },
  { path: "/docs/changelog", title: "Changelog" },
  { path: "/community", title: "Community" },
  { path: "/nightly", title: "Nightly" },
  { path: "/assets", title: "Brand Assets" },
] as const;

export function resolveAgentPageVariant(
  rawPath: string | null,
): AgentPageVariant | null {
  if (!rawPath) {
    return null;
  }

  const requestedPath = normalizeRequestedPath(rawPath);
  if (!requestedPath) {
    return null;
  }

  if (requestedPath === "/llms.txt") {
    return { kind: "llms", requestedPath };
  }

  if (
    reservedTextRoutes.has(requestedPath) ||
    blockedPrefixes.some(
      (prefix) => requestedPath === prefix || requestedPath.startsWith(`${prefix}/`),
    )
  ) {
    return null;
  }

  const extension = requestedPath.match(extensionPattern)?.[1]?.toLowerCase();
  if (extension !== "md" && extension !== "txt") {
    return null;
  }

  const canonicalPath = normalizeCanonicalPagePath(
    requestedPath.slice(0, -extension.length - 1),
  );
  if (!canonicalPath || !isKnownAgentReadablePage(canonicalPath)) {
    return null;
  }

  return {
    kind: "page",
    format: extension,
    requestedPath,
    canonicalPath,
  };
}

export function isAgentPageVariantPath(pathname: string): boolean {
  return resolveAgentPageVariant(pathname) !== null;
}

export function variantPathForPage(
  canonicalPath: string,
  format: AgentPageFormat,
): string {
  return canonicalPath === "/" ? `/index.${format}` : `${canonicalPath}.${format}`;
}

export function buildLlmsText(origin: string): string {
  const lines = [
    "# UniConnect",
    "",
    "Native macOS terminal built on Ghostty for running multiple AI coding agents.",
    "",
    "Every public HTML page supports Markdown and plain-text variants by appending `.md` or `.txt` to the page path. Text variants include `X-Robots-Tag: noindex, follow` and a canonical link header so search engines keep indexing the canonical HTML page.",
    "",
    "## Agent-readable pages",
    "",
    ...agentReadablePages.flatMap(({ path, title }) => [
      `- [${title}](${origin}${variantPathForPage(path, "md")})`,
      `  - Text: ${origin}${variantPathForPage(path, "txt")}`,
    ]),
    "",
    "Localized pages use the same extension pattern with the locale prefix, for example `/ja/docs/getting-started.md`.",
    "",
  ];

  return lines.join("\n");
}

function normalizeRequestedPath(rawPath: string): string | null {
  if (!rawPath.startsWith("/")) {
    return null;
  }
  if (rawPath.includes("\\") || rawPath.includes("\0")) {
    return null;
  }

  try {
    const decodedPath = decodeURI(rawPath);
    if (
      decodedPath.includes("\\") ||
      decodedPath.includes("\0") ||
      decodedPath.includes("..") ||
      decodedPath.includes("//")
    ) {
      return null;
    }
    return decodedPath;
  } catch {
    return null;
  }
}

function normalizeCanonicalPagePath(pathWithoutExtension: string): string | null {
  let path = pathWithoutExtension;

  if (path === "" || path === "/" || path === "/index") {
    return "/";
  }
  if (path.endsWith("/index")) {
    path = path.slice(0, -"/index".length) || "/";
  }

  path = normalizeEnglishLocalePrefix(path);

  if (path !== "/" && path.endsWith("/")) {
    path = path.slice(0, -1);
  }

  return path.startsWith("/") ? path : null;
}

function normalizeEnglishLocalePrefix(path: string): string {
  if (path === "/en") {
    return "/";
  }
  if (path.startsWith("/en/")) {
    return path.slice("/en".length) || "/";
  }
  return path;
}

const agentReadablePagePathSet: Set<string> = new Set(
  agentReadablePages.map(({ path }) => path),
);

function isKnownAgentReadablePage(canonicalPath: string): boolean {
  return agentReadablePagePathSet.has(basePagePath(canonicalPath));
}

function basePagePath(canonicalPath: string): string {
  for (const locale of locales) {
    if (canonicalPath === `/${locale}`) {
      return "/";
    }
    if (canonicalPath.startsWith(`/${locale}/`)) {
      return canonicalPath.slice(locale.length + 1) || "/";
    }
  }
  return canonicalPath;
}
