import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import "@/lib/i18n";
import { ImpersonationBanner } from "@/components/impersonation-banner";
import * as useAuthModule from "@/lib/use-auth";

/**
 * The banner is the only thing standing between "staff are looking at an
 * account" and "staff have forgotten whose account this is", so the tests
 * here are about presence and escape rather than appearance:
 *
 *   * it renders nothing at all outside a session — this component sits in
 *     `__root.tsx` and is therefore mounted for every visitor, signed in or
 *     not;
 *   * it names whose account this is;
 *   * Exit always works, including when the server call fails, because an
 *     admin who can't leave is the worst state this feature can reach.
 */

function mockAuth(overrides: Partial<ReturnType<typeof useAuthModule.useAuth>>) {
  vi.spyOn(useAuthModule, "useAuth").mockReturnValue({
    user: null,
    loading: false,
    impersonation: null,
    signOut: vi.fn(),
    refresh: vi.fn(),
    startImpersonation: vi.fn(),
    exitImpersonation: vi.fn(),
    ...overrides,
  } as unknown as ReturnType<typeof useAuthModule.useAuth>);
}

const inSession = {
  by_admin: true as const,
  reason: "Checking the publish error from ticket 412",
  expires_at: new Date(Date.now() + 25 * 60 * 1000).toISOString(),
};

describe("ImpersonationBanner", () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("renders nothing when nobody is impersonating", () => {
    mockAuth({ user: { id: "u1", email: "a@example.com" } as never });

    const { container } = render(<ImpersonationBanner />);

    expect(container).toBeEmptyDOMElement();
  });

  it("names the account being viewed and says it is read-only", () => {
    mockAuth({
      impersonation: inSession,
      user: { id: "u1", email: "dara@example.com", display_name: "Dara" } as never,
    });

    render(<ImpersonationBanner />);

    expect(screen.getByText(/Dara/)).toBeInTheDocument();
    expect(screen.getByText(/read-only/i)).toBeInTheDocument();
  });

  it("exits on demand", async () => {
    const exitImpersonation = vi.fn().mockResolvedValue(undefined);
    mockAuth({
      impersonation: inSession,
      user: { id: "u1", email: "d@example.com" } as never,
      exitImpersonation,
    });

    render(<ImpersonationBanner />);
    await userEvent.click(screen.getByRole("button", { name: /exit/i }));

    await waitFor(() => expect(exitImpersonation).toHaveBeenCalled());
  });

  // An admin must always be able to leave. If a failed exit left the button
  // spinning forever, the only way out would be clearing localStorage by hand.
  it("re-enables Exit when the server call fails", async () => {
    const exitImpersonation = vi.fn().mockRejectedValue(new Error("network"));
    mockAuth({
      impersonation: inSession,
      user: { id: "u1", email: "d@example.com" } as never,
      exitImpersonation,
    });

    render(<ImpersonationBanner />);
    const button = screen.getByRole("button", { name: /exit/i });
    await userEvent.click(button);

    await waitFor(() => expect(exitImpersonation).toHaveBeenCalled());
    await waitFor(() => expect(button).not.toBeDisabled());
  });
});
