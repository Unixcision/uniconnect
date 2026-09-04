import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import { describe, expect, test } from "bun:test";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  hiddenNotificationBody,
  shouldPruneToken,
} from "../services/apns/payload";
import { summarizeApnsSendResults } from "../services/apns/response";
import { sendApnsNotification, signApnsJwt, normalizeP8 } from "../services/apns/sender";
import {
  MAX_PUSH_BODY_CHARS,
  MAX_PUSH_LOCALE_CHARS,
  normalizeApnsBundle,
  parsePushPayload,
  readBoundedJsonObject,
} from "../services/apns/routePolicy";

describe("apns payload", () => {
  test("builds a time-sensitive alert with deep-link keys", () => {
    const payload = buildApnsPayload({
      title: "claude",
      subtitle: "issue-118",
      body: "Agent finished",
      workspaceId: "ws-1",
      surfaceId: "sf-2",
    }) as { aps: Record<string, unknown>; uniconnect: Record<string, string> };

    expect(payload.aps.alert).toEqual({ title: "claude", subtitle: "issue-118", body: "Agent finished" });
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload.aps.sound).toBe("default");
    expect(payload.uniconnect).toEqual({ workspaceId: "ws-1", surfaceId: "sf-2" });
  });

  test("omits UniConnect block when no ids", () => {
    const payload = buildApnsPayload({ title: "t", body: "b" }) as Record<string, unknown>;
    expect("uniconnect" in payload).toBe(false);
  });

  test("hideContent redacts terminal content but keeps a generic compatibility body and deep-link", () => {
    const payload = buildApnsPayload({
      title: "secret-host",
      subtitle: "secret",
      body: "rm -rf secret output",
      workspaceId: "ws-9",
      hideContent: true,
      locale: "es_ES",
    }) as { aps: { alert: Record<string, string> }; uniconnect: Record<string, string> };

    expect(payload.aps.alert.title).toBe("UniConnect");
    expect(payload.aps.alert.body).toBe("Un agente necesita tu atención");
    expect(payload.aps.alert.subtitle).toBeUndefined();
    expect(payload.uniconnect).toEqual({ workspaceId: "ws-9" });
  });

  test("hideContent localizes only from the bounded supported locale table", () => {
    const expected = new Map<string, string>([
      ["ar", "يحتاج وكيل إلى انتباهك"],
      ["bs", "Agent treba vašu pažnju"],
      ["da", "En agent har brug for din opmærksomhed"],
      ["de", "Ein Agent benötigt deine Aufmerksamkeit"],
      ["en", "An agent needs your attention"],
      ["es", "Un agente necesita tu atención"],
      ["fr", "Un agent a besoin de votre attention"],
      ["it", "Un agente richiede la tua attenzione"],
      ["ja", "エージェントが注意を必要としています"],
      ["km", "ភ្នាក់ងារត្រូវការការយកចិត្តទុកដាក់របស់អ្នក"],
      ["ko", "에이전트가 사용자의 주의를 필요로 합니다"],
      ["nb", "En agent trenger oppmerksomheten din"],
      ["pl", "Agent wymaga Twojej uwagi"],
      ["pt-BR", "Um agente precisa da sua atenção"],
      ["ru", "Агент требует вашего внимания"],
      ["th", "เอเจนต์ต้องการความสนใจจากคุณ"],
      ["tr", "Bir ajan dikkatinizi bekliyor"],
      ["uk", "Агент потребує вашої уваги"],
      ["zh-Hans", "某个智能体需要你的关注"],
      ["zh-Hant", "某個代理程式需要你的注意"],
    ]);

    expect(expected.size).toBe(20);
    for (const [locale, body] of expected) {
      expect(hiddenNotificationBody(locale)).toBe(body);
    }
    expect(hiddenNotificationBody("uk-UA")).toBe("Агент потребує вашої уваги");
    expect(hiddenNotificationBody("zh_TW")).toBe("某個代理程式需要你的注意");
    expect(hiddenNotificationBody("no-NO")).toBe("En agent trenger oppmerksomheten din");
    expect(hiddenNotificationBody("../../secret-host")).toBe("An agent needs your attention");
  });

  test("empty title falls back to UniConnect", () => {
    const payload = buildApnsPayload({ title: "   ", body: "b" }) as { aps: { alert: { title: string } } };
    expect(payload.aps.alert.title).toBe("UniConnect");
  });
});

describe("apns host + pruning", () => {
  test("host selection", () => {
    expect(apnsHostForEnvironment("sandbox")).toBe("api.sandbox.push.apple.com");
    expect(apnsHostForEnvironment("production")).toBe("api.push.apple.com");
    expect(apnsHostForEnvironment("unknown")).toBe("api.push.apple.com");
  });

  test("prunes only terminal failures", () => {
    expect(shouldPruneToken(410, undefined)).toBe(true);
    expect(shouldPruneToken(400, "BadDeviceToken")).toBe(true);
    expect(shouldPruneToken(400, "DeviceTokenNotForTopic")).toBe(true);
    expect(shouldPruneToken(200, undefined)).toBe(false);
    expect(shouldPruneToken(0, "timeout")).toBe(false); // transient
    expect(shouldPruneToken(503, "ServiceUnavailable")).toBe(false); // transient
    expect(shouldPruneToken(429, "TooManyRequests")).toBe(false);
  });
});

describe("apns response", () => {
  test("uses a stable summary shape when there are no devices", () => {
    expect(summarizeApnsSendResults([])).toEqual({ sent: 0, devices: 0, pruned: 0 });
  });

  test("summarizes sends without exposing provider reasons", () => {
    const summary = summarizeApnsSendResults([
      { deviceToken: "a".repeat(64), status: 200, prune: false },
      { deviceToken: "b".repeat(64), status: 400, reason: "BadDeviceToken", prune: true },
    ]);

    expect(summary).toEqual({ sent: 1, devices: 2, pruned: 1 });
    expect(JSON.stringify(summary)).not.toContain("BadDeviceToken");
    expect(JSON.stringify(summary)).not.toContain("apns");
  });
});

describe("apns route policy", () => {
  test("allows only UniConnect iOS bundle IDs and derives the APNs environment", () => {
    expect(normalizeApnsBundle("com.unixcision.uniconnect.ios")).toEqual({
      bundleId: "com.unixcision.uniconnect.ios",
      environment: "production",
    });
    expect(normalizeApnsBundle("com.unixcision.uniconnect.ios.beta")).toEqual({
      bundleId: "com.unixcision.uniconnect.ios.beta",
      environment: "production",
    });
    expect(normalizeApnsBundle("com.unixcision.uniconnect.ios.push1")).toEqual({
      bundleId: "com.unixcision.uniconnect.ios.push1",
      environment: "sandbox",
    });

    expect(normalizeApnsBundle("com.example.app")).toBeNull();
    expect(normalizeApnsBundle("com.unixcision.uniconnect.ios.bad_topic")).toBeNull();
    expect(normalizeApnsBundle("com.unixcision.uniconnect.ios.-bad")).toBeNull();
  });

  test("bounds and trims push payloads before sending to APNs", () => {
    const parsed = parsePushPayload({
      title: " agent ",
      subtitle: " workspace ",
      body: " done ",
      workspaceId: " ws-1 ",
      surfaceId: " sf-1 ",
      hideContent: true,
      locale: " es_ES ",
    });

    expect(parsed).toEqual({
      ok: true,
      value: {
        title: "agent",
        subtitle: "workspace",
        body: "done",
        workspaceId: "ws-1",
        surfaceId: "sf-1",
        hideContent: true,
        locale: "es_ES",
      },
    });

    expect(parsePushPayload({ title: "", body: "" })).toEqual({
      ok: false,
      error: "empty_notification",
    });
    expect(parsePushPayload({ title: "agent", body: "x".repeat(MAX_PUSH_BODY_CHARS + 1) })).toEqual({
      ok: false,
      error: "body_too_long",
    });
    expect(parsePushPayload({
      title: "agent",
      body: "done",
      locale: "x".repeat(MAX_PUSH_LOCALE_CHARS + 1),
    })).toEqual({
      ok: false,
      error: "locale_too_long",
    });
  });

  test("reads only bounded JSON objects from requests", async () => {
    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          headers: { "content-length": "9000" },
          body: "{}",
        }),
        8,
      ),
    ).resolves.toEqual({ ok: false, error: "request_too_large" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify({ body: "123456789" }),
        }),
        8,
      ),
    ).resolves.toEqual({ ok: false, error: "request_too_large" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify(["not", "object"]),
        }),
        64,
      ),
    ).resolves.toEqual({ ok: false, error: "invalid_json" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify({ title: "agent" }),
        }),
        64,
      ),
    ).resolves.toEqual({ ok: true, value: { title: "agent" } });
  });
});

describe("apns jwt", () => {
  test("normalizeP8 expands literal newlines", () => {
    expect(normalizeP8("a\\nb\\nc")).toBe("a\nb\nc");
    expect(normalizeP8("a\nb")).toBe("a\nb");
  });

  test("signs a verifiable ES256 JWT with kid/iss/iat", () => {
    const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const now = 1_700_000_000;
    const jwt = signApnsJwt({ keyP8: p8, keyId: "KID123", teamId: "TEAM456" }, now);

    const [headerB64, claimsB64, sigB64] = jwt.split(".");
    const decode = (s: string) =>
      JSON.parse(Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"));
    expect(decode(headerB64)).toEqual({ alg: "ES256", kid: "KID123" });
    expect(decode(claimsB64)).toEqual({ iss: "TEAM456", iat: now });

    const signature = Buffer.from(sigB64.replace(/-/g, "+").replace(/_/g, "/"), "base64");
    const valid = crypto.verify(
      "sha256",
      Buffer.from(`${headerB64}.${claimsB64}`),
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      signature,
    );
    expect(valid).toBe(true);
  });
});

describe("apns sender transport", () => {
  test("starts sandbox and production host groups concurrently", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production");
    const started: string[] = [];
    const closed: string[] = [];
    let releaseSandbox!: () => void;
    const sandboxReleased = new Promise<void>((resolve) => {
      releaseSandbox = resolve;
    });

    class FakeRequest extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        started.push(this.host);
        this.emit("response", { ":status": 200 });
        if (this.host === sandboxHost) {
          void sandboxReleased.then(() => this.emit("end"));
        } else {
          this.emit("end");
        }
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      request() {
        return new FakeRequest(this.host);
      }

      close() {
        closed.push(this.host);
      }
    }

    const transport = {
      connect: (host: string) => new FakeSession(host),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const resultPromise = sendApnsNotification(
      { keyP8: p8, keyId: "KID-CONCURRENT", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "com.unixcision.uniconnect.ios.push1", environment: "sandbox" },
        { deviceToken: "b".repeat(64), bundleId: "com.unixcision.uniconnect.ios", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    let results: Awaited<ReturnType<typeof sendApnsNotification>> = [];
    try {
      // Fake req.end() is synchronous here, so both host groups have started before any await.
      expect(started).toEqual([sandboxHost, productionHost]);
    } finally {
      releaseSandbox();
      results = await resultPromise;
    }

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost, sandboxHost]);
  });

  test("keeps healthy host results when another host cannot connect", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production");
    const closed: string[] = [];

    class FakeRequest extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      request() {
        return new FakeRequest(this.host);
      }

      close() {
        closed.push(this.host);
      }
    }

    const transport = {
      connect: (host: string) => {
        if (host === sandboxHost) {
          throw new Error("connect failed");
        }
        return new FakeSession(host);
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const results = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-PARTIAL", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "com.unixcision.uniconnect.ios.push1", environment: "sandbox" },
        { deviceToken: "b".repeat(64), bundleId: "com.unixcision.uniconnect.ios", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 0, reason: "connection_error", prune: false },
      { deviceToken: "b".repeat(64), status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost]);
  });

  test("keeps same-host successes when another request fails to start", async () => {
    const productionHost = apnsHostForEnvironment("production");
    const closed: string[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      private requestCount = 0;

      request() {
        this.requestCount += 1;
        if (this.requestCount === 2) {
          throw new Error("request failed");
        }
        return new FakeRequest();
      }

      close() {
        closed.push(productionHost);
      }
    }

    const transport = {
      connect: (host: string) => {
        expect(host).toBe(productionHost);
        return new FakeSession();
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const results = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-SAME-HOST-PARTIAL", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "com.unixcision.uniconnect.ios", environment: "production" },
        { deviceToken: "b".repeat(64), bundleId: "com.unixcision.uniconnect.ios.beta", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), status: 0, reason: "request failed", prune: false },
    ]);
    expect(closed).toEqual([productionHost]);
  });
});
