import { Link, useRouterState } from "@tanstack/react-router";
import { ChevronDown, LogOut, User, Wallet } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { LanguageSwitcher } from "@/components/language-switcher";
import { useAuth } from "@/lib/use-auth";
import { VerifyEmailBanner } from "@/components/verify-email-banner";

// Shared by every top-level nav item (both TanStack Router `Link`s and plain
// `<a>` section anchors) so hover/focus/active treatment stays consistent.
// `Link` automatically sets `data-status="active"` (and `aria-current`) on
// its rendered <a> when the route matches — the `data-[status=active]:`
// variants below key off that, so no manual pathname comparison is needed.
// Plain <a> tags simply never get that attribute, so those variants are a
// no-op for them; they still get hover/focus treatment.
const navLinkClass =
  "relative rounded-sm border-b-2 border-transparent px-0.5 pb-1.5 pt-1 outline-none transition-colors hover:border-border hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring data-[status=active]:border-primary data-[status=active]:font-medium data-[status=active]:text-foreground";

export function SiteHeader() {
  const { user, signOut } = useAuth();
  const { t } = useTranslation();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  // location.hash is stored without the leading "#" (e.g. "features").
  const hash = useRouterState({ select: (s) => s.location.hash });

  // The Features/Pricing/How-it-works items are plain <a href="/#section">
  // anchors, not TanStack Router `Link`s, so they never get the automatic
  // data-status="active" that Link sets on route change. They also don't
  // navigate to a different URL *pathname* — just a hash on the same "/" —
  // so we track which section is current from the hash instead and apply
  // the same active styling by hand.
  function sectionNavProps(section: string) {
    const isActive = hash === section;
    return {
      "data-status": isActive ? ("active" as const) : undefined,
      "aria-current": isActive ? ("location" as const) : undefined,
    };
  }

  const greetingName =
    user?.display_name?.trim() || user?.email.split("@")[0] || t("header.fallbackName");
  const initials = greetingName.slice(0, 2).toUpperCase();

  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur-xl">
      <VerifyEmailBanner />
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5">
        <Link to="/" className="flex items-center gap-2">
          <img
            src="/src/assets/logo.png"
            alt={t("common.rallyLogoAlt")}
            className="relative h-16 cursor-pointer"
          />

          <span className="font-display text-lg font-bold tracking-tight">Rally</span>
        </Link>

        <nav className="hidden items-center gap-8 text-sm text-muted-foreground md:flex">
          <Link to="/events" className={navLinkClass}>
            {t("header.browseEvents")}
          </Link>
          {user ? (
            <Link to="/dashboard" className={navLinkClass}>
              {t("header.dashboard")}
            </Link>
          ) : (
            <>
              <a href="/#features" className={navLinkClass} {...sectionNavProps("features")}>
                {t("header.features")}
              </a>
              <a href="/#pricing" className={navLinkClass} {...sectionNavProps("pricing")}>
                {t("header.pricing")}
              </a>
              <a href="/#how" className={navLinkClass} {...sectionNavProps("how")}>
                {t("header.howItWorks")}
              </a>
            </>
          )}
        </nav>

        <div className="flex items-center gap-2">
          <LanguageSwitcher />

          {user ? (
            <>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" size="sm" className="gap-2 pl-2">
                    <Avatar className="h-6 w-6">
                      <AvatarImage src={user.avatar_url ?? undefined} alt={greetingName} />
                      <AvatarFallback className="text-[10px]">{initials}</AvatarFallback>
                    </Avatar>
                    <span className="hidden max-w-[9rem] truncate sm:inline">
                      {t("header.welcome", { name: greetingName })}
                    </span>
                    <ChevronDown className="h-3.5 w-3.5 text-muted-foreground" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-60">
                  <DropdownMenuLabel className="font-normal">
                    <p className="truncate text-sm font-medium">{greetingName}</p>
                    <p className="truncate text-xs text-muted-foreground">{user.email}</p>
                  </DropdownMenuLabel>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem asChild>
                    <Link to="/profile" className="cursor-pointer">
                      <User className="h-4 w-4" /> {t("header.editProfile")}
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <Link to="/profile" hash="payment-settings" className="cursor-pointer">
                      <Wallet className="h-4 w-4" /> {t("header.paymentSettings")}
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem
                    onClick={() => signOut()}
                    className="cursor-pointer text-destructive focus:text-destructive"
                  >
                    <LogOut className="h-4 w-4" /> {t("common.signOut")}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          ) : (
            pathname !== "/auth" && (
              <Button asChild variant="hero" size="sm">
                <Link to="/auth">{t("common.signIn")}</Link>
              </Button>
            )
          )}
        </div>
      </div>
    </header>
  );
}
