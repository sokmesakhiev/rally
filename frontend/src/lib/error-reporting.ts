import * as Sentry from "@sentry/react";

/**
 * Frontend error tracking.
 *
 * Replaces the old `lovable-error-reporting.ts`, which posted to
 * `window.__lovableEvents` — a hook only present inside the Lovable preview
 * environment, so in real deployments it silently did nothing.
 *
 * Gated entirely behind VITE_SENTRY_DSN (see .env.example), same philosophy as
 * the Google Maps / Google OAuth integrations: unset, `initErrorReporting()`
 * returns without initializing and `reportError()` becomes a no-op, so local
 * development and self-hosted builds need no Sentry account.
 */

const SENTRY_DSN = import.meta.env.VITE_SENTRY_DSN as string | undefined;

let initialized = false;

export function initErrorReporting() {
  // Guard against double-init: TanStack Start renders on the server too, and
  // this is called from the root route's effect on the client.
  if (initialized || !SENTRY_DSN || typeof window === "undefined") return;

  Sentry.init({
    dsn: SENTRY_DSN,
    environment: (import.meta.env.VITE_SENTRY_ENVIRONMENT as string) ?? import.meta.env.MODE,

    // Ties errors to a deploy. Set at build time in CI from the git SHA so
    // frontend and backend releases can be correlated in Sentry.
    release: import.meta.env.VITE_GIT_SHA as string | undefined,

    // 10% of transactions — enough for latency trends without a large bill.
    tracesSampleRate: 0.1,

    // Session Replay off by default: it records DOM mutations, which on this
    // app would include registration forms and survey answers. Turning it on
    // should be a deliberate decision about what's being captured.
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,

    // Don't send PII (IP addresses, and with replay/DOM capture, form values).
    // Matches the backend's send_default_pii = false.
    sendDefaultPii: false,

    // Filter noise that isn't actionable: browser extension errors, and the
    // benign ResizeObserver loop warning some browsers emit during layout.
    ignoreErrors: [
      "ResizeObserver loop limit exceeded",
      "ResizeObserver loop completed with undelivered notifications",
      /^chrome-extension:\/\//,
      /^moz-extension:\/\//,
    ],
  });

  initialized = true;
}

/**
 * Report a caught error. Safe to call whether or not Sentry is configured —
 * with no DSN, Sentry.init was never called and captureException no-ops.
 */
export function reportError(error: unknown, context: Record<string, unknown> = {}) {
  if (typeof window === "undefined") return;

  Sentry.captureException(error, {
    extra: {
      route: window.location.pathname,
      ...context,
    },
  });
}

/**
 * Associate subsequent events with the signed-in user (id only, never email —
 * see the backend's matching ApplicationController#set_sentry_user). Pass null
 * on sign-out to clear it.
 */
export function setErrorReportingUser(userId: string | null) {
  if (!initialized) return;
  Sentry.setUser(userId ? { id: userId } : null);
}
