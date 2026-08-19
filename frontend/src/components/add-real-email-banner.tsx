import { Mail } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/lib/use-auth";

/** Shown site-wide (see SiteHeader) for a phone-only guest checkout account
 * (Registrations::GuestCheckout) — `user.email` is an auto-generated
 * placeholder nobody can read, so this nudges them to add a real one
 * whenever they're ready, without blocking anything in the meantime.
 * Mutually exclusive with VerifyEmailBanner — see that component's guard. */
export function AddRealEmailBanner() {
  const { user } = useAuth();
  const { t } = useTranslation();

  if (!user || !user.email_auto_generated) return null;

  return (
    <div className="flex flex-wrap items-center justify-center gap-3 bg-amber-500/10 px-4 py-2 text-center text-sm text-amber-700 dark:text-amber-400">
      <span className="flex items-center gap-1.5">
        <Mail className="h-4 w-4" /> {t("addRealEmailBanner.message")}
      </span>
      <Button asChild size="sm" variant="outline" className="h-7 border-amber-500/40 text-xs">
        <Link to="/profile">{t("addRealEmailBanner.cta")}</Link>
      </Button>
    </div>
  );
}
