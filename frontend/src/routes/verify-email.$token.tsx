import { useEffect, useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Activity, Loader2, Check, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { emailVerificationsApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";

export const Route = createFileRoute("/verify-email/$token")({
  head: () => ({
    meta: [{ title: "Verify your email — Rally" }],
  }),
  component: VerifyEmailPage,
});

type State = "checking" | "success" | "error";

function VerifyEmailPage() {
  const { token } = Route.useParams();
  const { user, refresh } = useAuth();
  const [state, setState] = useState<State>("checking");

  useEffect(() => {
    let cancelled = false;
    emailVerificationsApi
      .confirm(token)
      .then(async () => {
        if (cancelled) return;
        if (user) await refresh();
        setState("success");
      })
      .catch(() => {
        if (!cancelled) setState("error");
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <div className="w-full max-w-sm text-center">
        <Link to="/" className="mb-8 inline-flex items-center gap-2">
          <span className="flex h-8 w-8 items-center justify-center rounded-lg [background-image:var(--gradient-hero)]">
            <Activity className="h-5 w-5 text-primary-foreground" />
          </span>
          <span className="font-display text-lg font-bold">Rally</span>
        </Link>

        <div className="mt-4 rounded-2xl border border-border bg-card p-8">
          {state === "checking" && (
            <>
              <Loader2 className="mx-auto h-8 w-8 animate-spin text-muted-foreground" />
              <p className="mt-3 text-sm text-muted-foreground">Verifying your email…</p>
            </>
          )}
          {state === "success" && (
            <>
              <Check className="mx-auto h-8 w-8 text-primary" />
              <h1 className="mt-3 font-display text-xl font-bold">Email verified</h1>
              <p className="mt-2 text-sm text-muted-foreground">
                Your email address has been confirmed.
              </p>
              <Button asChild variant="hero" className="mt-6 w-full">
                <Link to={user ? "/dashboard" : "/auth"}>{user ? "Go to dashboard" : "Sign in"}</Link>
              </Button>
            </>
          )}
          {state === "error" && (
            <>
              <X className="mx-auto h-8 w-8 text-destructive" />
              <h1 className="mt-3 font-display text-xl font-bold">Link invalid or expired</h1>
              <p className="mt-2 text-sm text-muted-foreground">
                This verification link is no longer valid. Sign in and request a new one.
              </p>
              <Button asChild variant="outline" className="mt-6 w-full">
                <Link to="/auth">Back to sign in</Link>
              </Button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
