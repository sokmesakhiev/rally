import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Eye, Loader2, LogOut } from "lucide-react";

import { useAuth } from "@/lib/use-auth";
import { Button } from "@/components/ui/button";

/**
 * The bar that says "you are not who this page thinks you are".
 *
 * Mounted once from `__root.tsx`, beside `SupportChat`, and renders `null` for
 * everyone not in a staff support session — which is everyone, almost always.
 *
 * Two things it deliberately does *not* do:
 *
 *   * **It doesn't disable anything.** The rest of the app renders exactly as
 *     the impersonated user sees it, Save buttons included, and a write that
 *     reaches the server comes back `403 impersonation_read_only`. Graying out
 *     every mutating control would mean maintaining a second, parallel model
 *     of "what is a write" in the client — the list that goes stale, the way
 *     the manage-event tab grid did. Letting the refusal come from the one
 *     place that actually enforces it keeps the client honest.
 *   * **It doesn't hide.** No dismiss button, no auto-collapse. An admin who
 *     forgets which account they're in is the failure this exists to prevent,
 *     and a banner you can close is a banner you will close.
 *
 * The countdown is read from the server's `expires_at` rather than counted
 * from when the session opened, so a clock that drifts or a tab that slept
 * can't show time that doesn't exist.
 */
export function ImpersonationBanner() {
  const { t } = useTranslation();
  const { impersonation, user, exitImpersonation } = useAuth();
  const [leaving, setLeaving] = useState(false);
  const [remaining, setRemaining] = useState<number>(0);

  const expiresAt = impersonation?.expires_at;

  useEffect(() => {
    if (!expiresAt) return;

    const tick = () => setRemaining(Math.max(0, new Date(expiresAt).getTime() - Date.now()));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [expiresAt]);

  if (!impersonation) return null;

  const minutes = Math.floor(remaining / 60000);
  const seconds = Math.floor((remaining % 60000) / 1000);
  const expired = remaining <= 0;

  const leave = async () => {
    setLeaving(true);
    try {
      await exitImpersonation();
    } catch {
      // Swallowed on purpose. `exitImpersonation` clears the local key in its
      // own `finally`, so the session is already over on this machine whatever
      // the server said; re-throwing here would only leave an unhandled
      // rejection and a button that looks broken. An admin must always be able
      // to leave, including when the network isn't cooperating.
    } finally {
      setLeaving(false);
    }
  };

  return (
    <div
      // `role="status"` rather than "alert": this is a persistent condition,
      // not an interruption, and an alert would be re-announced by a screen
      // reader on every re-render of the countdown.
      role="status"
      className="sticky top-0 z-50 flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-amber-500/40 bg-amber-500/15 px-4 py-2 text-sm backdrop-blur"
    >
      <Eye className="h-4 w-4 shrink-0" aria-hidden="true" />
      <span className="font-medium">
        {t("impersonation.viewingAs", {
          name: user?.display_name || user?.email || "",
        })}
      </span>
      <span className="text-muted-foreground">{t("impersonation.readOnly")}</span>
      <span className="ml-auto flex items-center gap-3">
        <span className="tabular-nums text-muted-foreground">
          {expired
            ? t("impersonation.expired")
            : t("impersonation.timeLeft", {
                time: `${minutes}:${String(seconds).padStart(2, "0")}`,
              })}
        </span>
        <Button size="sm" variant="outline" onClick={leave} disabled={leaving}>
          {leaving ? <Loader2 className="h-4 w-4 animate-spin" /> : <LogOut className="h-4 w-4" />}
          {t("impersonation.exit")}
        </Button>
      </span>
    </div>
  );
}
