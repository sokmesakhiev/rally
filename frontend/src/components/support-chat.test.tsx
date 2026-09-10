import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

// Initialises the i18next singleton. Without it `t()` returns raw keys, and
// these assertions would match "supportChat.send" rather than "Send" — passing
// for the wrong reason and never catching a broken translation.
import "@/lib/i18n";
import { SupportChat } from "@/components/support-chat";
import { supportApi } from "@/lib/api-client";
import * as useAuthModule from "@/lib/use-auth";
import * as supportCable from "@/lib/support-cable";

/**
 * Covers the parts with real consequences: the anonymous gate (which is also
 * what keeps a socket from ever opening for a logged-out visitor), and the
 * optimistic send path including its failure state — a composer that silently
 * swallows a message is the worst outcome this component can produce.
 *
 * The socket itself is stubbed. Exercising real ActionCable in jsdom would test
 * the library rather than this component, and the hook's contract with it —
 * tear down and rebuild on every reconnect, because tickets are single-use —
 * is verified against a real server by scripts/cable-smoke.mjs instead.
 */

function stubUser(user: { id: string } | null) {
  vi.spyOn(useAuthModule, "useAuth").mockReturnValue({
    user,
    loading: false,
  } as unknown as ReturnType<typeof useAuthModule.useAuth>);
}

function renderChat() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <SupportChat />
    </QueryClientProvider>,
  );
}

describe("SupportChat", () => {
  beforeEach(() => {
    // Never let a test reach the real transport.
    vi.spyOn(supportCable, "openCableConsumer").mockResolvedValue({
      subscriptions: { create: () => ({ unsubscribe: vi.fn() }) },
      disconnect: vi.fn(),
    } as unknown as Awaited<ReturnType<typeof supportCable.openCableConsumer>>);

    vi.spyOn(supportApi, "conversation").mockResolvedValue({ conversation: null });
    vi.spyOn(supportApi, "messages").mockResolvedValue({
      conversation: null,
      messages: [],
      has_more: false,
    });
  });

  it("renders nothing for an anonymous visitor", () => {
    stubUser(null);

    const { container } = renderChat();

    expect(container).toBeEmptyDOMElement();
    expect(supportApi.conversation).not.toHaveBeenCalled();
  });

  it("shows the launcher once signed in, without opening a socket", async () => {
    stubUser({ id: "user-1" });

    renderChat();

    expect(await screen.findByRole("button", { name: /support/i })).toBeInTheDocument();
    // The panel is shut, so nothing should have connected yet — the badge
    // comes from the REST poll.
    expect(supportCable.openCableConsumer).not.toHaveBeenCalled();
  });

  it("opens a socket only when the panel is opened", async () => {
    stubUser({ id: "user-1" });
    renderChat();

    await userEvent.click(await screen.findByRole("button", { name: /support/i }));

    await waitFor(() => expect(supportCable.openCableConsumer).toHaveBeenCalled());
  });

  it("shows a sent message optimistically", async () => {
    stubUser({ id: "user-1" });
    vi.spyOn(supportApi, "sendMessage").mockImplementation(
      () => new Promise(() => {}), // never resolves: the bubble must appear anyway
    );

    renderChat();
    await userEvent.click(await screen.findByRole("button", { name: /support/i }));

    const box = await screen.findByRole("textbox");
    await userEvent.type(box, "My ticket is missing");
    await userEvent.click(screen.getByRole("button", { name: /send/i }));

    expect(await screen.findByText("My ticket is missing")).toBeInTheDocument();
  });

  // The message must not vanish. Someone who typed a paragraph and lost it to a
  // dropped connection will not type it again.
  it("keeps a failed message on screen with a retry", async () => {
    stubUser({ id: "user-1" });
    vi.spyOn(supportApi, "sendMessage").mockRejectedValue(new Error("network"));

    renderChat();
    await userEvent.click(await screen.findByRole("button", { name: /support/i }));

    const box = await screen.findByRole("textbox");
    await userEvent.type(box, "Where is my refund");
    await userEvent.click(screen.getByRole("button", { name: /send/i }));

    expect(await screen.findByText("Where is my refund")).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: /retry/i })).toBeInTheDocument();
  });
});
