import { describe, expect, test } from "bun:test";

import { resolveSiteURL } from "../lib/site";

describe("resolveSiteURL", () => {
  test("uses a reserved non-routable origin when configuration is missing", () => {
    expect(resolveSiteURL(undefined)).toBe("https://uniconnect.invalid");
    expect(resolveSiteURL("   ")).toBe("https://uniconnect.invalid");
  });

  test("accepts only HTTPS and normalizes an owned origin", () => {
    expect(resolveSiteURL("https://example.com/path///?secret=1#fragment")).toBe(
      "https://example.com",
    );
    expect(resolveSiteURL("http://example.com")).toBe(
      "https://uniconnect.invalid",
    );
    expect(resolveSiteURL("https://user:secret@example.com")).toBe(
      "https://uniconnect.invalid",
    );
    expect(resolveSiteURL("not a URL")).toBe("https://uniconnect.invalid");
  });
});
