import "@fontsource-variable/sora/index.css";
import "@fontsource-variable/inter/index.css";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, type ReactNode } from "react";
import { useTranslation } from "react-i18next";

import appCss from "../styles.css?url";
import { initErrorReporting, reportError } from "../lib/error-reporting";
import { AuthProvider } from "../lib/use-auth";
import { applyStoredLanguage } from "../lib/i18n";
import { Toaster } from "../components/ui/sonner";
import { SiteFooter } from "../components/site-footer";
import iconUrl from "@/assets/icon.png";

function NotFoundComponent() {
  const { t } = useTranslation();
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">{t("notFound.title")}</h2>
        <p className="mt-2 text-sm text-muted-foreground">{t("notFound.description")}</p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            {t("common.goHome")}
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  const { t } = useTranslation();
  useEffect(() => {
    reportError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold tracking-tight text-foreground">
          {t("errorPage.title")}
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">{t("errorPage.description")}</p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            {t("common.tryAgain")}
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent"
          >
            {t("common.goHome")}
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Rally — Create & Join Running Events" },
      {
        name: "description",
        content:
          "Rally is the easiest way to organize running races, group rides, and community gatherings. Set up an event in minutes and bring people together.",
      },
      { name: "author", content: "Rally" },
      { property: "og:title", content: "Rally — Create & Join Running Events" },
      {
        property: "og:description",
        content:
          "Organize running races, group rides, and community gatherings. Set up an event in minutes.",
      },
      { property: "og:type", content: "website" },
      { property: "og:image", content: iconUrl },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:site", content: "@Rally" },
    ],
    links: [
      {
        rel: "stylesheet",
        href: appCss,
      },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();

  // Client-only, post-hydration: apply a saved language preference. Doing
  // this here (rather than at module scope) keeps the server's render and
  // the client's first render identical — both always start in English.
  useEffect(() => {
    applyStoredLanguage();
  }, []);

  // Client-only: initialize error reporting. No-ops without VITE_SENTRY_DSN.
  useEffect(() => {
    initErrorReporting();
  }, []);

  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        {/* Required: nested routes render here. Removing <Outlet /> breaks all child routes. */}
        <div className="flex min-h-screen flex-col">
          <Outlet />
          <SiteFooter />
        </div>
        <Toaster />
      </AuthProvider>
    </QueryClientProvider>
  );
}
