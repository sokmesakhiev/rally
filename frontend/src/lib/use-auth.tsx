import { createContext, useContext, useEffect, useState, useCallback, type ReactNode } from "react";
import {
  adminImpersonationApi,
  authApi,
  clearImpersonationToken,
  clearToken,
  getImpersonationToken,
  getToken,
  setImpersonationToken,
  type ApiImpersonationState,
  type ApiUser,
} from "@/lib/api-client";
import { setErrorReportingUser } from "@/lib/error-reporting";

interface AuthState {
  /** The logged-in user, or null if not authenticated. During a staff support
   *  session this is the **impersonated** user — which is the point: every
   *  screen then renders exactly what that person sees, with no component
   *  needing to know. */
  user: ApiUser | null;
  /** True while the initial auth check is in progress. */
  loading: boolean;
  /** Non-null only during a staff support session. Comes from the server on
   *  every `/auth/me`, so a refresh can't lose it. */
  impersonation: ApiImpersonationState | null;
  /** Sign out and clear the stored token. */
  signOut: () => void;
  /** Re-fetch the current user (e.g. after a profile update). */
  refresh: () => Promise<void>;
  /** Open a support session as `userId` and switch the app into it. */
  startImpersonation: (userId: string, reason: string) => Promise<void>;
  /** Leave a support session and return to the admin's own account. */
  exitImpersonation: () => Promise<void>;
}

const AuthContext = createContext<AuthState | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<ApiUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [impersonation, setImpersonation] = useState<ApiImpersonationState | null>(null);

  const refresh = useCallback(async () => {
    const token = getToken();
    if (!token) {
      setUser(null);
      setImpersonation(null);
      setLoading(false);
      return;
    }
    try {
      const { user: me, impersonation: imp } = await authApi.me();
      setUser(me);
      setImpersonation(imp ?? null);
    } catch {
      // A dead *impersonation* token must not sign the admin out of their own
      // account — the session expiring after 30 minutes is the normal ending,
      // not a credentials failure. Drop that key and re-read as themselves;
      // only a failure with no impersonation in play clears the real token.
      if (getImpersonationToken()) {
        clearImpersonationToken();
        setImpersonation(null);
        try {
          const { user: me } = await authApi.me();
          setUser(me);
        } catch {
          clearToken();
          setUser(null);
        }
      } else {
        clearToken();
        setUser(null);
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // Tag error reports with the signed-in user's id (id only — no email; see
  // lib/error-reporting.ts). No-ops when Sentry isn't configured.
  useEffect(() => {
    setErrorReportingUser(user?.id ?? null);
  }, [user?.id]);

  const signOut = useCallback(() => {
    // Ending the *server* session first, and not just dropping the local key.
    // Clearing the key alone left the row live: no `end_impersonation` audit
    // entry, and — because one live session per admin is a unique index — the
    // admin couldn't start another until the 30 minutes ran out. The comment
    // here used to claim sign-out ended the session while the code only
    // forgot about it.
    //
    // Fire-and-forget on purpose: `end()` is idempotent, it carries the
    // admin's own token (already attached by the time the fetch starts, so
    // clearing below can't strand it), and signing out must not be blocked by
    // a request that might fail. Worst case the row expires on its own.
    if (getImpersonationToken()) {
      void adminImpersonationApi.end().catch(() => {});
    }

    clearImpersonationToken();
    authApi.signout();
    setImpersonation(null);
    setUser(null);
  }, []);

  const startImpersonation = useCallback(
    async (userId: string, reason: string) => {
      const { token } = await adminImpersonationApi.start(userId, reason);
      setImpersonationToken(token);
      await refresh();
    },
    [refresh],
  );

  const exitImpersonation = useCallback(async () => {
    // Server first, then the key: the DELETE goes out with the admin's own
    // token, so it works either way, but ending the row before dropping the
    // token means a failure leaves the session visibly still open rather than
    // stranding a live row nobody can see. `end()` is idempotent, and the
    // local key is cleared even if it throws — an admin must always be able to
    // leave.
    try {
      await adminImpersonationApi.end();
    } finally {
      clearImpersonationToken();
      setImpersonation(null);
      await refresh();
    }
  }, [refresh]);

  return (
    <AuthContext.Provider
      value={{
        user,
        loading,
        impersonation,
        signOut,
        refresh,
        startImpersonation,
        exitImpersonation,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
