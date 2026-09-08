import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Bell, BellOff, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { usePushNotifications } from "@/lib/use-push-notifications";
import { cn } from "@/lib/utils";

interface PushNotificationPromptProps {
  /** Brand colour of the event this is shown alongside, if any. */
  brandColor?: string;
  className?: string;
}

/**
 * Offers to turn on push notifications, tied to an explicit click.
 *
 * Rendered after a successful registration — the one moment the value is
 * concrete ("tell me when my payment clears") rather than abstract ("allow
 * notifications?"). The browser prompt only appears once the user presses the
 * button here, never on mount. See usePushNotifications for why that matters.
 *
 * Renders nothing at all when:
 *   - the browser can't do push (iOS Safari outside an installed PWA, mostly)
 *   - the server has no VAPID keypair, so there'd be nothing to subscribe to
 *   - permission was already denied — there is no API to ask again, and a
 *     button that silently does nothing is worse than no button
 *   - this device is already subscribed
 */
export function PushNotificationPrompt({ brandColor, className }: PushNotificationPromptProps) {
  const { t } = useTranslation();
  const { supported, enabled, permission, subscribed, busy, subscribe } = usePushNotifications();
  const [dismissed, setDismissed] = useState(false);

  if (!supported || !enabled || subscribed || dismissed) return null;
  if (permission === "denied") return null;

  return (
    <div className={cn("rounded-lg border border-border bg-muted/40 px-4 py-3", className)}>
      <div className="flex items-start gap-3">
        <Bell className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium">{t("pushNotifications.title")}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">{t("pushNotifications.body")}</p>

          <div className="mt-3 flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              disabled={busy}
              onClick={() => void subscribe()}
              style={brandColor ? { backgroundColor: brandColor } : undefined}
              className={brandColor ? "text-white hover:opacity-90" : undefined}
            >
              {busy && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
              {t("pushNotifications.enable")}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => setDismissed(true)}>
              {t("pushNotifications.notNow")}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

/**
 * The settings-page counterpart: a plain on/off control for someone who has
 * already made a decision and wants to change it. No persuasion, no dismissal.
 */
export function PushNotificationToggle({ className }: { className?: string }) {
  const { t } = useTranslation();
  const { supported, enabled, permission, subscribed, busy, subscribe, unsubscribe } =
    usePushNotifications();

  if (!supported || !enabled) return null;

  return (
    <div className={cn("flex items-center justify-between gap-4", className)}>
      <div className="min-w-0">
        <p className="text-sm font-medium">{t("pushNotifications.title")}</p>
        <p className="text-xs text-muted-foreground">
          {permission === "denied"
            ? t("pushNotifications.blocked")
            : t("pushNotifications.settingsBody")}
        </p>
      </div>

      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={busy || permission === "denied"}
        onClick={() => void (subscribed ? unsubscribe() : subscribe())}
      >
        {busy ? (
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
        ) : subscribed ? (
          <BellOff className="h-3.5 w-3.5" />
        ) : (
          <Bell className="h-3.5 w-3.5" />
        )}
        {subscribed ? t("pushNotifications.turnOff") : t("pushNotifications.enable")}
      </Button>
    </div>
  );
}
