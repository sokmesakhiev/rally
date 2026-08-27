import { createFileRoute, Link } from "@tanstack/react-router";
import { Activity } from "lucide-react";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Terms of Service — Rally" },
      { name: "description", content: "Rally's Terms of Service." },
    ],
  }),
  component: TermsPage,
});

// Placeholder copy, not reviewed legal text — see
// event-freeze-and-terms-tickets.md's Ticket G. The mechanism (required
// checkbox + versioned acceptance record, see TermsOfService::CURRENT_VERSION
// server-side) is real; this wording is a stand-in until legal review swaps
// it out before launch.
function TermsPage() {
  const { t } = useTranslation();

  return (
    <div className="min-h-screen bg-background">
      <div className="mx-auto max-w-2xl px-6 py-12">
        <Link to="/" className="inline-flex items-center gap-2">
          <Activity className="h-5 w-5 text-primary" />
          <span className="font-display text-lg font-bold">Rally</span>
        </Link>

        <div className="mt-8 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
          {t("legal.draftNotice")}
        </div>

        <h1 className="mt-8 font-display text-3xl font-bold">{t("legal.termsTitle")}</h1>
        <p className="mt-2 text-sm text-muted-foreground">{t("legal.lastUpdated", { date: "2026-08-27" })}</p>

        <div className="mt-6 space-y-4 text-sm leading-relaxed text-muted-foreground">
          <p>{t("legal.termsIntro")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsAccountsTitle")}</h2>
          <p>{t("legal.termsAccountsBody")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsEventsTitle")}</h2>
          <p>{t("legal.termsEventsBody")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsPaymentsTitle")}</h2>
          <p>{t("legal.termsPaymentsBody")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsConductTitle")}</h2>
          <p>{t("legal.termsConductBody")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsTerminationTitle")}</h2>
          <p>{t("legal.termsTerminationBody")}</p>
          <h2 className="font-display text-lg font-semibold text-foreground">{t("legal.termsContactTitle")}</h2>
          <p>{t("legal.termsContactBody")}</p>
        </div>

        <p className="mt-10 text-center text-xs text-muted-foreground">
          <Link to="/auth" className="hover:text-foreground">
            ← {t("common.backToHome")}
          </Link>
        </p>
      </div>
    </div>
  );
}
