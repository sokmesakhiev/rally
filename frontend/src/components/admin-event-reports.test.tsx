import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import "@/lib/i18n";
import { AdminEventReports } from "@/components/admin-event-reports";
import {
  adminEventReportsApi,
  type ApiEventReport,
  type ApiEventReportGroup,
} from "@/lib/api-client";

/**
 * Covers the three things whose breaking would change what the queue *means*,
 * rather than how it looks:
 *
 *   * filters reach the API (a queue filtered client-side over one page shows
 *     a reviewer the wrong worklist);
 *   * an anonymous report renders as a report, not as broken data — accepting
 *     them without an account is the design;
 *   * resolving posts to the resolve endpoint and **never** suspends. That
 *     separation is the whole reason report counts can't be weaponised, and a
 *     well-meaning "and take it down too" would be a one-line change.
 */

const group: ApiEventReportGroup = {
  event: {
    id: "evt-1",
    title: "Midnight Fight Night",
    description: "Bring your gloves.",
    category: "other",
    location: "Phnom Penh",
    start_at: new Date().toISOString(),
    is_published: true,
    visibility: "public",
    suspended: false,
    suspension_reason: null,
    organization: { slug: "kh-fights", name: "KH Fights" },
  },
  report_count: 4,
  open_count: 4,
  priority: "high",
  reasons: { violence: 3, other: 1 },
  last_reported_at: new Date().toISOString(),
};

const anonymousReport: ApiEventReport = {
  id: "rep-1",
  reason: "violence",
  details: "This is advertising an unlicensed fight.",
  status: "open",
  created_at: new Date().toISOString(),
  reporter: null,
  reviewed_by: null,
  reviewed_at: null,
  reviewer_note: null,
};

function renderPanel() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <AdminEventReports />
    </QueryClientProvider>,
  );
}

describe("AdminEventReports", () => {
  beforeEach(() => {
    vi.spyOn(adminEventReportsApi, "list").mockResolvedValue({
      reports: [group],
      meta: { page: 1, per_page: 25, total_count: 1, total_pages: 1 },
      open_count: 1,
    });

    vi.spyOn(adminEventReportsApi, "event").mockResolvedValue({
      event: group.event,
      reports: [anonymousReport],
      total_count: 1,
    });

    vi.spyOn(adminEventReportsApi, "resolve").mockResolvedValue({
      resolved: 1,
      status: "dismissed",
    });
  });

  it("lists reported events and sends filters to the server", async () => {
    renderPanel();

    expect(await screen.findByText("Midnight Fight Night")).toBeInTheDocument();
    // The landing view is the worklist, expressed by sending no status at all.
    expect(adminEventReportsApi.list).toHaveBeenCalledWith({
      status: undefined,
      reason: undefined,
      page: 1,
    });

    await userEvent.click(screen.getByRole("button", { name: /dismissed/i }));

    await waitFor(() =>
      expect(adminEventReportsApi.list).toHaveBeenCalledWith({
        status: "dismissed",
        reason: undefined,
        page: 1,
      }),
    );
  });

  // Filtering from a later page used to land on a page that no longer exists
  // in the narrowed result, which renders as "nothing matches".
  it("returns to page 1 when a filter changes", async () => {
    vi.mocked(adminEventReportsApi.list).mockResolvedValue({
      reports: [group],
      meta: { page: 1, per_page: 25, total_count: 60, total_pages: 3 },
      open_count: 60,
    });

    renderPanel();

    await userEvent.click(await screen.findByRole("button", { name: /next/i }));
    await waitFor(() =>
      expect(adminEventReportsApi.list).toHaveBeenCalledWith(expect.objectContaining({ page: 2 })),
    );

    await userEvent.click(screen.getByRole("button", { name: /dismissed/i }));

    await waitFor(() =>
      expect(adminEventReportsApi.list).toHaveBeenCalledWith(
        expect.objectContaining({ status: "dismissed", page: 1 }),
      ),
    );
  });

  it("renders an anonymous report as a report, not as missing data", async () => {
    renderPanel();

    await userEvent.click(await screen.findByText("Midnight Fight Night"));

    expect(await screen.findByText("This is advertising an unlicensed fight.")).toBeInTheDocument();
    expect(screen.getByText(/anonymous/i)).toBeInTheDocument();
  });

  it("resolves the reports without suspending the event", async () => {
    renderPanel();

    await userEvent.click(await screen.findByText("Midnight Fight Night"));
    // `/dismiss \(/` and not `/dismiss/`: the status filter above the list is
    // also called "Dismissed", and the count is what distinguishes the action.
    await userEvent.click(await screen.findByRole("button", { name: /dismiss \(/i }));

    await waitFor(() =>
      expect(adminEventReportsApi.resolve).toHaveBeenCalledWith("evt-1", "dismissed", ""),
    );

    // Nothing in this panel may take an event down: suspension is its own act
    // on the Events tab, with its own audit entry.
    expect(screen.queryByRole("button", { name: /suspend/i })).not.toBeInTheDocument();
  });
});
