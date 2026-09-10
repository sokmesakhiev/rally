/**
 * Minimal types for `@rails/actioncable`, which ships none of its own.
 *
 * Declared here rather than pulling in a `@types` package: this app uses four
 * methods of the API, and a hand-written declaration that covers exactly what
 * we call is both smaller and honest about the surface we depend on. Note
 * `tsconfig.json` restricts `compilerOptions.types` to an explicit list, so an
 * ambient `@types` package wouldn't be picked up automatically anyway.
 */
declare module "@rails/actioncable" {
  export interface Subscription {
    unsubscribe(): void;
    /** Invokes a server-side channel action. Unused — both of this app's
     *  channels are receive-only, and every write goes over REST. */
    perform(action: string, data?: Record<string, unknown>): void;
  }

  export interface Subscriptions {
    create(
      channel: string | { channel: string; [key: string]: unknown },
      handlers: {
        connected?(): void;
        disconnected?(): void;
        rejected?(): void;
        received?(data: unknown): void;
      },
    ): Subscription;
  }

  export interface Consumer {
    subscriptions: Subscriptions;
    /** Closes the socket and stops ActionCable's own reconnect monitor. */
    disconnect(): void;
  }

  /**
   * `url` may be a function, which ActionCable re-evaluates on every reconnect.
   * This app deliberately passes a plain string and rebuilds the whole consumer
   * instead — see the note in `lib/support-cable.ts` about single-use tickets.
   */
  export function createConsumer(url: string | (() => string)): Consumer;
}
