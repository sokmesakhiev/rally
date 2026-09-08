import { useCallback, useEffect, useState } from "react";
import { pushApi } from "@/lib/api-client";

/**
 * Web push subscription state and actions.
 *
 * The permission prompt is NEVER triggered from this hook's effects — only
 * from `subscribe()`, which callers must wire to an explicit user action.
 * Browsers penalise sites that prompt on page load (Chrome and Firefox both
 * suppress the prompt entirely for users who habitually dismiss it), and a
 * permission denied on arrival is close to unrecoverable: there's no API to
 * ask again, the user has to dig through site settings.
 *
 * `supported` and `enabled` are different things. `supported` is the browser
 * (iOS Safari only gained web push in 16.4, and only for installed PWAs);
 * `enabled` is whether the server has a VAPID keypair configured at all.
 * Either being false means render nothing.
 */

const SERVICE_WORKER_PATH = "/sw.js";

export type PushPermission = "default" | "granted" | "denied" | "unsupported";

interface PushState {
  supported: boolean;
  enabled: boolean;
  permission: PushPermission;
  subscribed: boolean;
  busy: boolean;
}

function browserSupportsPush(): boolean {
  return (
    typeof window !== "undefined" &&
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  );
}

/**
 * VAPID keys travel as base64url text, but `applicationServerKey` wants raw
 * bytes. Base64url isn't base64: it swaps two characters and drops padding,
 * so `atob` alone produces the wrong bytes and the subscribe call fails with
 * an opaque InvalidAccessError.
 */
function urlBase64ToUint8Array(base64: string): Uint8Array {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = window.atob(normalized);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);
  return output;
}

/** The browser hands back an ArrayBuffer; the API wants base64url text. */
function encodeKey(buffer: ArrayBuffer | null): string {
  if (!buffer) return "";
  const bytes = new Uint8Array(buffer);
  let binary = "";
  bytes.forEach((b) => {
    binary += String.fromCharCode(b);
  });
  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function usePushNotifications() {
  const [state, setState] = useState<PushState>({
    supported: false,
    enabled: false,
    permission: "unsupported",
    subscribed: false,
    busy: false,
  });

  // Read-only probing: what the browser allows, whether the server has keys,
  // and whether this device is already subscribed. Deliberately asks for
  // nothing — no permission prompt, no service worker registration.
  useEffect(() => {
    let cancelled = false;

    async function probe() {
      if (!browserSupportsPush()) return;

      try {
        const { enabled } = await pushApi.vapidPublicKey();
        const registration = await navigator.serviceWorker.getRegistration();
        const existing = await registration?.pushManager.getSubscription();

        if (cancelled) return;
        setState({
          supported: true,
          enabled,
          permission: Notification.permission as PushPermission,
          subscribed: Boolean(existing),
          busy: false,
        });
      } catch {
        // A failed probe means "don't offer this", not an error worth
        // surfacing — nothing the user did has failed yet.
        if (!cancelled) setState((s) => ({ ...s, supported: true, enabled: false }));
      }
    }

    void probe();
    return () => {
      cancelled = true;
    };
  }, []);

  /** Call from a click handler. Never from an effect. */
  const subscribe = useCallback(async (): Promise<boolean> => {
    if (!browserSupportsPush()) return false;
    setState((s) => ({ ...s, busy: true }));

    try {
      const { enabled, public_key: publicKey } = await pushApi.vapidPublicKey();
      if (!enabled || !publicKey) {
        setState((s) => ({ ...s, enabled: false, busy: false }));
        return false;
      }

      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState((s) => ({ ...s, permission: permission as PushPermission, busy: false }));
        return false;
      }

      // Registered only now, not during probing — no reason to install a
      // service worker on a device whose owner hasn't asked for notifications.
      const registration = await navigator.serviceWorker.register(SERVICE_WORKER_PATH);
      await navigator.serviceWorker.ready;

      // Chrome requires userVisibleOnly: true and rejects silent push outright.
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(publicKey),
      });

      await pushApi.subscribe({
        endpoint: subscription.endpoint,
        p256dhKey: encodeKey(subscription.getKey("p256dh")),
        authKey: encodeKey(subscription.getKey("auth")),
      });

      setState((s) => ({ ...s, permission: "granted", subscribed: true, busy: false }));
      return true;
    } catch {
      setState((s) => ({ ...s, busy: false }));
      return false;
    }
  }, []);

  const unsubscribe = useCallback(async (): Promise<void> => {
    setState((s) => ({ ...s, busy: true }));
    try {
      const registration = await navigator.serviceWorker.getRegistration();
      const subscription = await registration?.pushManager.getSubscription();
      if (subscription) {
        // Tell the server first. If the order were reversed and the API call
        // failed, the browser would have dropped the subscription while the
        // server kept pushing to a dead endpoint.
        await pushApi.unsubscribe(subscription.endpoint);
        await subscription.unsubscribe();
      }
      setState((s) => ({ ...s, subscribed: false, busy: false }));
    } catch {
      setState((s) => ({ ...s, busy: false }));
    }
  }, []);

  return { ...state, subscribe, unsubscribe };
}
