import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach, vi } from "vitest";

// Unmount anything rendered by the previous test. Without this, queries like
// getByText can match leftover DOM from an earlier example.
afterEach(() => {
  cleanup();
});

// The app stores its JWT in localStorage under "rally_token" (see
// lib/api-client.ts). jsdom gives us a real localStorage, but it persists
// across tests in the same file — clear it so token state never leaks between
// examples.
beforeEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
});
