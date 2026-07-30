import { createContext, useContext, useEffect, useState, useCallback, type ReactNode } from "react";
import { authApi, getToken, clearToken, type ApiUser } from "@/lib/api-client";
import { setErrorReportingUser } from "@/lib/error-reporting";

interface AuthState {
  /** The logged-in user, or null if not authenticated. */
  user: ApiUser | null;
  /** True while the initial auth check is in progress. */
  loading: boolean;
  /** Sign out and clear the stored token. */
  signOut: () => void;
  /** Re-fetch the current user (e.g. after a profile update). */
  refresh: () => Promise<void>;
}

const AuthContext = createContext<AuthState | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<ApiUser | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const token = getToken();
    if (!token) {
      setUser(null);
      setLoading(false);
      return;
    }
    try {
      const { user: me } = await authApi.me();
      setUser(me);
    } catch {
      clearToken();
      setUser(null);
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
    authApi.signout();
    setUser(null);
  }, []);

  return (
    <AuthContext.Provider value={{ user, loading, signOut, refresh }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
