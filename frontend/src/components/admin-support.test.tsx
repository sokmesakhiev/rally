import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import "@/lib/i18n";
import { AdminSupport } from "@/components/admin-support";
import { adminSupportApi, type ApiAdminConversation } from "@/lib/api-client";
import * as useAuthModule from "@/lib/use-auth";
import * as supportInbox from "@/lib/use-support-inbox";

/**
 * Covers the parts an agent would notice breaking: the filters actually reach
 * the API, the participant context renders beside the thread (which is the
 * whole reason this is built in-house), and a reply posts.
 *
 * The inbox socket is stubbed out — it only invalidates queries, so exercising
 * it here would test react-query rather than this component.
 */

const conversation: ApiAdminConversation = {
  id: "conv-1",
  status: "open",
  subject: "Missing ticket",
  unread: true,
  assigned_admin_id: null,
  last_message_at: new Date().toISOString(),
  created_at: new Date().toISOString(),
  participant: { id: "user-9", display_name: "Dara", email: "dara@example.com" },
};

function renderPanel() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <AdminSupport />
    </QueryClientProvider>,
  );
}

describe("AdminSupport", () => {
  beforeEach(() => {
    vi.spyOn(useAuthModule, "useAuth").mockReturnValue({
      user: { id: "admin-1", admin: true },
      loading: false,
    } as unknown as ReturnType<typeof useAuthModule.useAuth>);

    vi.spyOn(supportInbox, "useSupportInbox").mockImplementation(() => {});

    vi.spyOn(adminSupportApi, "conversations").mockResolvedValue({
      conversations: [conversation],
      meta: { page: 1, per_page: 25, total_count: 1, total_pages: 1 },
      awaiting_count: 1,
    });

    vi.spyOn(adminSupportApi, "markRead").mockResolvedValue({
      conversation: { ...conversation, staff_last_read_at: null, participant_last_read_at: null },
    });

    vi.spyOn(adminSupportApi, "conversation").mockResolvedValue({
      conversation: { ...conversation, staff_last_read_at: null, participant_last_read_at: null },
      participant: {
        id: "user-9",
        email: "dara@example.com",
        display_name: "Dara",
        suspended: false,
        created_at: new Date().toISOString(),
        registrations: [
          {
            id: "reg-1",
            event_title: "Angkor Half Marathon",
            status: "confirmed",
            payment_status: "paid",
            amount_paid_cents: 2500,
            refunded_cents: 0,
            created_at: new Date().toISOString(),
          },
        ],
      },
      messages: [
        {
          id: "msg-1",
          body: "I never got my ticket",
          sender_role: "participant",
          sender_id: "user-9",
          sender_name: null,
          created_at: new Date().toISOString(),
        },
      ],
    });
  });

  it("lists conversations and reports how many are waiting on us", async () => {
    renderPanel();

    expect(await screen.findByText("Dara")).toBeInTheDocument();
    expect(screen.getByText(/waiting on us/i)).toBeInTheDocument();
  });

  // The default view is "live" — open plus pending — because that's what an
  // inbox is for. Switching must actually reach the API, not just restyle.
  it("defaults to live and passes filter changes through to the API", async () => {
    renderPanel();
    await screen.findByText("Dara");

    expect(adminSupportApi.conversations).toHaveBeenCalledWith(
      expect.objectContaining({ status: "live", assignment: "any" }),
    );

    await userEvent.click(screen.getByRole("button", { name: /^resolved$/i }));

    await waitFor(() =>
      expect(adminSupportApi.conversations).toHaveBeenCalledWith(
        expect.objectContaining({ status: "resolved" }),
      ),
    );
  });

  it("passes the unread filter only when switched on", async () => {
    renderPanel();
    await screen.findByText("Dara");

    await userEvent.click(screen.getByRole("button", { name: /unread only/i }));

    await waitFor(() =>
      expect(adminSupportApi.conversations).toHaveBeenCalledWith(
        expect.objectContaining({ unread: true }),
      ),
    );
  });

  // The context sidebar is the argument for building this rather than
  // embedding a hosted widget — if it stops rendering, that argument is gone.
  it("shows the thread with the participant's Rally activity", async () => {
    renderPanel();

    await userEvent.click(await screen.findByText("Dara"));

    expect(await screen.findByText("I never got my ticket")).toBeInTheDocument();
    expect(screen.getByText("Angkor Half Marathon")).toBeInTheDocument();
    expect(screen.getByText(/Paid/)).toBeInTheDocument();
  });

  it("marks the thread read when it is opened", async () => {
    renderPanel();

    await userEvent.click(await screen.findByText("Dara"));

    await waitFor(() => expect(adminSupportApi.markRead).toHaveBeenCalledWith("conv-1"));
  });

  it("sends a reply", async () => {
    const reply = vi.spyOn(adminSupportApi, "reply").mockResolvedValue({
      message: {
        id: "msg-2",
        body: "Resending it now",
        sender_role: "staff",
        sender_id: "admin-1",
        sender_name: "Admin",
        created_at: new Date().toISOString(),
      },
      conversation: { ...conversation, staff_last_read_at: null, participant_last_read_at: null },
    });

    renderPanel();
    await userEvent.click(await screen.findByText("Dara"));

    const box = await screen.findByRole("textbox");
    await userEvent.type(box, "Resending it now");
    await userEvent.click(screen.getByRole("button", { name: /send/i }));

    await waitFor(() => expect(reply).toHaveBeenCalledWith("conv-1", "Resending it now"));
  });
});
