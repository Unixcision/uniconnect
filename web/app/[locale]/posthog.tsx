"use client";

import posthog from "posthog-js";
import { PostHogProvider as PHProvider } from "posthog-js/react";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";

const projectKey = process.env.NEXT_PUBLIC_UNICONNECT_POSTHOG_KEY?.trim();
const apiHost = process.env.NEXT_PUBLIC_UNICONNECT_POSTHOG_HOST?.trim();

if (typeof window !== "undefined" && projectKey && apiHost) {
  posthog.init(projectKey, {
    api_host: apiHost,
    ui_host: process.env.NEXT_PUBLIC_UNICONNECT_POSTHOG_UI_HOST?.trim() || "https://us.posthog.com",
    person_profiles: "identified_only",
    capture_pageview: false,
    capture_pageleave: true,
  });
}

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (pathname && posthog) {
      let url = window.origin + pathname;
      const search = searchParams.toString();
      if (search) url += "?" + search;
      posthog.capture("$pageview", { $current_url: url });
    }
  }, [pathname, searchParams]);

  return null;
}

export function PostHogProvider({ children }: { children: React.ReactNode }) {
  return (
    <PHProvider client={posthog}>
      <Suspense fallback={null}>
        <PageviewTracker />
      </Suspense>
      {children}
    </PHProvider>
  );
}
