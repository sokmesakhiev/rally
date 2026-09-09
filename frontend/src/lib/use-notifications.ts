import { useEffect } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { notificationsApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";

export const NOTIFICATIONS_QUERY_KEY = ["notifications"] as const;

/**
 * How often an open tab re-checks. A minute is a deliberate ceiling, not a
 * placeholder: production runs 3 Puma threads per task across 2 tasks, so
 * every open tab is competing for six request threads that also serve
 * registrations and payments. Polling faster buys latency the push signal
 * below already provides for free.
 */
const POLL_INTERVAL_MS = 60_000;

/**
 * The header bell's data.
 *
 * "Real time" here is two mechanisms, not one:
 *
 *   1. The service worker receives a web push and messages open tabs
 *      (see public/sw.js), which invalidates this query immediately. For
 *      anyone who granted notification permission, the badge updates the
 *      moment the server sends anything.
 *   2. A 60-second poll, which covers everyone else — people who declined
 *      permission, browsers without push support (iOS Safari outside an
 *      installed PWA), and any message the worker missed.
 *
 * Deliberately NOT a WebSocket or SSE connection. Either would hold one of six
 * total Puma threads open per connected user, and six people with the app open
 * would saturate the API.
 */
export function useNotifications() {
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const enabled = Boolean(user);

  const query = useQuery({
    queryKey: NOTIFICATIONS_QUERY_KEY,
    queryFn: () => notificationsApi.list(),
    enabled,
    refetchInterval: enabled ? POLL_INTERVAL_MS : false,
    // A background tab polling is wasted work — nobody is looking at the
    // badge. It refetches on focus instead, so the count is fresh the instant
    // someone comes back.
    refetchIntervalInBackground: false,
    staleTime: 30_000,
  });

  // Mechanism 1. Registered here rather than in the component so it survives
  // the dropdown opening and closing.
  useEffect(() => {
    if (!enabled || typeof navigator === "undefined" || !("serviceWorker" in navigator)) {
      return;
    }

    const onMessage = (event: MessageEvent) => {
      if (event.data?.type !== "rally:notification") return;
      void queryClient.invalidateQueries({ queryKey: NOTIFICATIONS_QUERY_KEY });
    };

    navigator.serviceWorker.addEventListener("message", onMessage);
    return () => navigator.serviceWorker.removeEventListener("message", onMessage);
  }, [enabled, queryClient]);

  const markRead = useMutation({
    mutationFn: (id: string) => notificationsApi.markRead(id),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: NOTIFICATIONS_QUERY_KEY }),
  });

  const markAllRead = useMutation({
    mutationFn: () => notificationsApi.markAllRead(),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: NOTIFICATIONS_QUERY_KEY }),
  });

  return {
    notifications: query.data?.notifications ?? [],
    unreadCount: query.data?.unread_count ?? 0,
    maxCount: query.data?.max_count ?? 99,
    isLoading: query.isLoading,
    markRead,
    markAllRead,
  };
}
