import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { Bell } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Button } from "@/components/ui/button";
import { useNotifications } from "@/lib/use-notifications";
import type { ApiNotification } from "@/lib/api-client";
import { cn } from "@/lib/utils";

/**
 * The header bell: an unread count, and a dropdown of recent notifications.
 *
 * Renders only for signed-in users — `useNotifications` disables its query
 * without a session, so an anonymous visitor never polls.
 */
export function NotificationBell() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { notifications, unreadCount, maxCount, markRead, markAllRead } = useNotifications();

  const hasUnread = unreadCount > 0;
  // The server caps the count, so anything at the ceiling is "or more".
  const badgeLabel = unreadCount > maxCount ? `${maxCount}+` : String(unreadCount);

  function open(notification: ApiNotification) {
    if (!notification.read) markRead.mutate(notification.id);
    const destination = notificationDestination(notification.url);
    if (destination) void navigate(destination);
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="relative"
          aria-label={
            hasUnread
              ? t("notifications.ariaWithCount", { count: unreadCount })
              : t("notifications.aria")
          }
        >
          <Bell className="h-5 w-5" />
          {hasUnread && (
            <span
              className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-semibold leading-none text-white"
              // The count is already in the button's aria-label; announcing it
              // twice makes the control read as "notifications 3 notifications".
              aria-hidden="true"
            >
              {badgeLabel}
            </span>
          )}
        </Button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-80">
        <div className="flex items-center justify-between gap-2 px-2 py-1.5">
          <DropdownMenuLabel className="p-0">{t("notifications.title")}</DropdownMenuLabel>
          {hasUnread && (
            <button
              type="button"
              className="text-xs text-muted-foreground underline-offset-2 hover:underline"
              onClick={() => markAllRead.mutate()}
              disabled={markAllRead.isPending}
            >
              {t("notifications.markAllRead")}
            </button>
          )}
        </div>
        <DropdownMenuSeparator />

        {notifications.length === 0 ? (
          <p className="px-2 py-6 text-center text-sm text-muted-foreground">
            {t("notifications.empty")}
          </p>
        ) : (
          <div className="max-h-96 overflow-y-auto">
            {notifications.map((notification) => (
              <DropdownMenuItem
                key={notification.id}
                onSelect={() => open(notification)}
                className={cn(
                  "flex cursor-pointer flex-col items-start gap-0.5 whitespace-normal py-2",
                  !notification.read && "bg-muted/50",
                )}
              >
                <span className="flex w-full items-start gap-2">
                  {!notification.read && (
                    <span
                      className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary"
                      aria-hidden="true"
                    />
                  )}
                  <span className="text-sm font-medium">{notification.title}</span>
                </span>
                {notification.body && (
                  <span className="text-xs text-muted-foreground">{notification.body}</span>
                )}
                <span className="text-[11px] text-muted-foreground">
                  {formatRelative(notification.created_at, t)}
                </span>
              </DropdownMenuItem>
            ))}
          </div>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

// `url` comes over the wire as a plain string, untyped against the router's
// route literals. An allowlist rather than a pass-through: if a future kind
// ever sends a path this map doesn't know about, silently not navigating is far
// safer than handing an arbitrary string to `navigate` — worst case is a click
// that only marks the row read, not a runtime throw or (if the string were ever
// attacker-influenced) an open redirect.
//
// The values are full navigate options rather than bare paths because
// `ModerationNotifier` deep-links to a *tab* (`/admin?tab=reports`), and
// TanStack's `to` takes a route literal with `search` passed separately. Doing
// the split here keeps the URL the backend stores readable as a URL.
const NOTIFICATION_DESTINATIONS = {
  "/dashboard": { to: "/dashboard" },
  "/admin?tab=reports": { to: "/admin", search: { tab: "reports" } },
} as const;

function notificationDestination(url: string | null | undefined) {
  if (!url) return null;
  return NOTIFICATION_DESTINATIONS[url as keyof typeof NOTIFICATION_DESTINATIONS] ?? null;
}

/**
 * Coarse relative time — "3h ago" is what matters on a notification, and this
 * avoids pulling a formatting library in for four buckets.
 */
function formatRelative(iso: string, t: (key: string, opts?: object) => string): string {
  const minutes = Math.floor((Date.now() - new Date(iso).getTime()) / 60_000);

  if (minutes < 1) return t("notifications.justNow");
  if (minutes < 60) return t("notifications.minutesAgo", { count: minutes });

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t("notifications.hoursAgo", { count: hours });

  return t("notifications.daysAgo", { count: Math.floor(hours / 24) });
}
