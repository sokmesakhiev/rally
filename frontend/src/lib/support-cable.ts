import { cableApi, cableUrl } from "@/lib/api-client";

/**
 * ActionCable plumbing for support chat, kept out of every other bundle.
 *
 * `@rails/actioncable` is imported dynamically so a visitor who never opens the
 * chat panel never downloads it — which is most visitors, on a page whose job
 * is selling event registrations.
 */

import type { Consumer, Subscription } from "@rails/actioncable";

// Re-exported under local names so callers depend on this module rather than
// on the library directly — the seam that would let a polling fallback swap in
// without touching the hook or the components.
export type CableConsumer = Consumer;
export type CableSubscription = Subscription;

type ActionCableModule = typeof import("@rails/actioncable");

let modulePromise: Promise<ActionCableModule> | null = null;

function loadActionCable(): Promise<ActionCableModule> {
  // Cached: the import is idempotent, but a user toggling the panel shouldn't
  // re-enter the module resolution path each time.
  modulePromise ??= import("@rails/actioncable") as Promise<ActionCableModule>;
  return modulePromise;
}

/**
 * Opens a fresh, authenticated consumer.
 *
 * **A consumer is single-use and must be thrown away on disconnect.** The
 * ticket in its URL is spent the moment the server redeems it, so ActionCable's
 * own reconnect logic — which replays the same URL — would retry forever
 * against a credential that can never work again. `useSupportChat` therefore
 * tears the whole consumer down on `disconnected` and calls this again rather
 * than letting the built-in monitor retry. That also puts the backoff and the
 * visible "reconnecting" state under our control instead of the library's.
 */
export async function openCableConsumer(): Promise<CableConsumer> {
  // Ticket first: no point loading the module if the caller isn't
  // authenticated, and a failure here is the one worth surfacing.
  const { ticket } = await cableApi.ticket();
  const { createConsumer } = await loadActionCable();

  return createConsumer(cableUrl(ticket));
}
