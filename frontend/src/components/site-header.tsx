import { Link, useRouterState } from "@tanstack/react-router";
import { Activity } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/lib/use-auth";
import { VerifyEmailBanner } from "@/components/verify-email-banner";

export function SiteHeader() {
  const { user, signOut } = useAuth();
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur-xl">
      <VerifyEmailBanner />
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5">
        <Link to="/" className="flex items-center gap-2">
          <span className="flex h-8 w-8 items-center justify-center rounded-lg [background-image:var(--gradient-hero)]">
            <Activity className="h-5 w-5 text-primary-foreground" />
          </span>
          <span className="font-display text-lg font-bold tracking-tight">Rally</span>
        </Link>

        <nav className="hidden items-center gap-8 text-sm text-muted-foreground md:flex">
          <Link to="/events" className="transition-colors hover:text-foreground">Browse events</Link>
          {user ? (
            <Link to="/dashboard" className="transition-colors hover:text-foreground">Dashboard</Link>
          ) : (
            <>
              <a href="/#features" className="transition-colors hover:text-foreground">Features</a>
              <a href="/#how" className="transition-colors hover:text-foreground">How it works</a>
            </>
          )}
        </nav>

        <div className="flex items-center gap-3">
          {user ? (
            <>
              <Button asChild variant="hero" size="sm">
                <Link to="/dashboard">Dashboard</Link>
              </Button>
              <Button variant="outline" size="sm" onClick={() => signOut()}>
                Sign out
              </Button>
            </>
          ) : (
            pathname !== "/auth" && (
              <Button asChild variant="hero" size="sm">
                <Link to="/auth">Sign in</Link>
              </Button>
            )
          )}
        </div>
      </div>
    </header>
  );
}
