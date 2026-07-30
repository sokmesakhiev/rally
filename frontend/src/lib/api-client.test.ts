import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

import {
  ApiError,
  authApi,
  eventsApi,
  registrationsApi,
  getToken,
  setToken,
  clearToken,
} from "@/lib/api-client";

/**
 * These tests cover the fetch wrapper's contract with the Rails API — auth
 * header attachment, error unwrapping, and the machine-readable `code` field
 * the capacity/plan endpoints rely on. That contract is the thing most likely
 * to break silently when the backend's JSON shape changes, and until now
 * nothing verified it at all.
 */

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** The Request/RequestInit pair fetch was last called with. */
function lastCall() {
  const mock = globalThis.fetch as unknown as ReturnType<typeof vi.fn>;
  const [url, init] = mock.mock.calls.at(-1) as [string, RequestInit];
  return { url, init, headers: (init.headers ?? {}) as Record<string, string> };
}

describe("api-client", () => {
  beforeEach(() => {
    vi.stubGlobal("fetch", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe("token helpers", () => {
    it("round-trips a token through localStorage under the rally_token key", () => {
      expect(getToken()).toBeNull();

      setToken("abc123");

      expect(getToken()).toBe("abc123");
      // Pinned deliberately: use-auth.tsx and the Rails backend both assume
      // this exact key, so renaming it would silently sign every user out.
      expect(localStorage.getItem("rally_token")).toBe("abc123");

      clearToken();

      expect(getToken()).toBeNull();
    });
  });

  describe("request wrapper", () => {
    it("sends no Authorization header when there is no stored token", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ events: [] }),
      );

      await eventsApi.list();

      expect(lastCall().headers.Authorization).toBeUndefined();
    });

    it("attaches the stored token as a Bearer header", async () => {
      setToken("tok-xyz");
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ events: [] }),
      );

      await eventsApi.list();

      expect(lastCall().headers.Authorization).toBe("Bearer tok-xyz");
    });

    it("prefixes every path with /api/v1", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ events: [] }),
      );

      await eventsApi.list();

      expect(lastCall().url).toContain("/api/v1/events");
    });

    it("throws ApiError carrying the backend's error message on a non-2xx response", async () => {
      // mockImplementation, not mockResolvedValue: a Response body can only be
      // read once, so two awaited calls need two distinct Response objects.
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockImplementation(() =>
        Promise.resolve(jsonResponse({ error: "Event not found" }, 404)),
      );

      await expect(eventsApi.get("missing-id")).rejects.toThrowError(ApiError);
      await expect(eventsApi.get("missing-id")).rejects.toThrow("Event not found");
    });

    it("preserves the machine-readable code alongside the message", async () => {
      // `code: "full"` is what the registration UI keys off to lock the form
      // and refresh capacity, rather than string-matching the message — see
      // RegistrationsController#capacity_error_json.
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ error: "This event is full", code: "full" }, 422),
      );

      const err = await registrationsApi.create("event-1", {}).catch((e: unknown) => e);

      expect(err).toBeInstanceOf(ApiError);
      expect((err as ApiError).code).toBe("full");
      expect((err as ApiError).message).toBe("This event is full");
    });

    it("falls back to a status-based message when the body has no error field", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(jsonResponse({}, 500));

      await expect(eventsApi.list()).rejects.toThrow("API error 500");
    });

    it("handles an empty response body without throwing a JSON parse error", async () => {
      // e.g. a 204-style response — `text` is "" and must not be JSON.parse'd.
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        new Response("", { status: 200 }),
      );

      await expect(eventsApi.list()).resolves.toEqual({});
    });
  });

  describe("authApi", () => {
    it("stores the returned token on successful signin", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ token: "new-token", user: { id: "u1" } }),
      );

      await authApi.signin("runner@example.com", "password123");

      expect(getToken()).toBe("new-token");
    });

    it("does not store a token when signin fails", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ error: "Invalid email or password" }, 401),
      );

      await expect(authApi.signin("runner@example.com", "wrong")).rejects.toThrow();
      expect(getToken()).toBeNull();
    });

    it("posts the Google ID token under id_token, matching AuthController#google", async () => {
      (globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue(
        jsonResponse({ token: "t", user: { id: "u1" } }),
      );

      await authApi.google("google-credential-jwt");

      const { url, init } = lastCall();
      expect(url).toContain("/auth/google");
      expect(JSON.parse(init.body as string)).toEqual({ id_token: "google-credential-jwt" });
    });
  });
});
