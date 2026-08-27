import { useState, useEffect } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { Activity, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { GoogleSignInButton } from "@/components/google-sign-in-button";
import { authApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { getRecaptchaToken } from "@/lib/recaptcha";
import logoUrl from "@/assets/logo.png";

const GOOGLE_SIGN_IN_ENABLED = Boolean(import.meta.env.VITE_GOOGLE_CLIENT_ID);

export const Route = createFileRoute("/auth")({
  head: () => ({
    meta: [
      { title: "Sign in — Rally" },
      {
        name: "description",
        content: "Sign in or create your Rally account to start organizing events.",
      },
    ],
  }),
  component: AuthPage,
});

const emailSchema = z.string().trim().email().max(255);
const passwordSchema = z.string().min(8).max(72);

function AuthPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
  const { user, loading: authLoading, refresh, signOut } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  // See event-freeze-and-terms-tickets.md's Ticket H. A brand-new Google
  // account never sees the sign-up form's checkbox, so its
  // terms_accepted_at comes back null — this gate is shown once, right
  // after that credential exchange, before navigating into the dashboard.
  // A returning Google user (terms_accepted_at already set) never sees it.
  const [showTermsGate, setShowTermsGate] = useState(false);
  const [termsGateAccepted, setTermsGateAccepted] = useState(false);
  const [termsGateLoading, setTermsGateLoading] = useState(false);

  useEffect(() => {
    // `!showTermsGate` matters here: right after a brand-new Google sign-in,
    // `refresh()` already makes `user` truthy, which would otherwise fire
    // this redirect and blow straight past the acceptance gate below before
    // its own navigate call ever runs.
    if (!authLoading && user && !showTermsGate) {
      navigate({ to: "/dashboard", replace: true });
    }
  }, [user, authLoading, navigate, showTermsGate]);

  const validate = () => {
    const e = emailSchema.safeParse(email);
    if (!e.success) {
      toast.error(t("auth.errors.invalidEmail"));
      return false;
    }
    const p = passwordSchema.safeParse(password);
    if (!p.success) {
      toast.error(t("auth.errors.passwordTooShort"));
      return false;
    }
    return true;
  };

  // Sign-up only — sign-in has no confirm-password field or terms checkbox
  // to check. The backend rejects signup without terms_accepted: true
  // regardless (see event-freeze-and-terms-tickets.md's Ticket F) — this is
  // just the same "catch the obvious case before a round-trip" pattern the
  // rest of this function already uses for email/password.
  const validateSignUp = () => {
    if (!validate()) return false;
    if (password !== confirmPassword) {
      toast.error(t("auth.errors.passwordMismatch"));
      return false;
    }
    if (!termsAccepted) {
      toast.error(t("auth.errors.termsNotAccepted"));
      return false;
    }
    return true;
  };

  const handleSignIn = async () => {
    if (!validate()) return;
    setLoading(true);
    try {
      await authApi.signin(email, password);
      // AuthProvider only fetches the current user once, on its own mount —
      // storing the token alone doesn't update its `user` state. Without
      // this, the header keeps showing "Sign in" and any dashboard query
      // gated on `user` never fires, until a full page reload remounts
      // AuthProvider and it re-fetches on its own.
      await refresh();
      toast.success(t("auth.welcomeBack"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("auth.errors.signInFailed"));
    } finally {
      setLoading(false);
    }
  };

  const handleSignUp = async () => {
    if (!validateSignUp()) return;
    setLoading(true);
    try {
      // Resolves to undefined when VITE_RECAPTCHA_SITE_KEY isn't configured
      // — the backend only enforces verification once RECAPTCHA_SECRET_KEY
      // is also set, so signup still works either way.
      const recaptchaToken = await getRecaptchaToken("signup");
      await authApi.signup(email, password, termsAccepted, displayName.trim() || undefined, recaptchaToken);
      await refresh();
      toast.success(t("auth.accountCreated"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("auth.errors.signUpFailed"));
    } finally {
      setLoading(false);
    }
  };

  const handleGoogleCredential = async (idToken: string) => {
    setGoogleLoading(true);
    try {
      const res = await authApi.google(idToken);
      await refresh();
      if (!res.user.terms_accepted_at) {
        // Brand-new Google account — hold off on navigating until they've
        // seen the gate below and accepted.
        setShowTermsGate(true);
        return;
      }
      toast.success(t("auth.welcomeBack"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("auth.errors.signInFailed"));
    } finally {
      setGoogleLoading(false);
    }
  };

  const handleAcceptTermsGate = async () => {
    if (!termsGateAccepted) return;
    setTermsGateLoading(true);
    try {
      await authApi.acceptTerms();
      await refresh();
      setShowTermsGate(false);
      toast.success(t("auth.welcomeBack"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("common.genericError"));
    } finally {
      setTermsGateLoading(false);
    }
  };

  // Escape hatch for someone who doesn't want to accept right now — signs
  // them back out rather than trapping them on this screen. Their account
  // still exists with terms_accepted_at nil; they'll see this gate again
  // next time they sign in with Google.
  const handleDeclineTermsGate = () => {
    signOut();
    setShowTermsGate(false);
    setTermsGateAccepted(false);
  };

  return (
    <div className="flex min-h-screen flex-col bg-background md:flex-row">
      {/* Brand panel */}
      <div className="relative hidden flex-1 flex-col justify-between overflow-hidden p-12 md:flex [background-image:var(--gradient-surface)]">
        <Link to="/" className="flex items-center gap-2">
          <img
            src={logoUrl}
            alt={t("common.rallyLogoAlt")}
            className="relative h-16 cursor-pointer"
          />
          <span className="font-display text-lg font-bold">Rally</span>
        </Link>
        <div>
          <h2 className="font-display text-4xl font-bold leading-tight">
            {t("auth.brand.titlePrefix")}{" "}
            <span className="text-gradient">{t("auth.brand.titleHighlight")}</span>.
          </h2>
          <p className="mt-4 max-w-md text-muted-foreground">{t("auth.brand.subtitle")}</p>
        </div>
        <p className="text-sm text-muted-foreground">© {new Date().getFullYear()} Rally</p>
      </div>

      {/* Form panel */}
      <div className="flex flex-1 items-center justify-center p-6">
        <div className="w-full max-w-sm">
          <div className="mb-8 text-center md:hidden">
            <Link to="/" className="inline-flex items-center gap-2">
              <Activity className="h-5 w-5 text-primary" />
              <span className="font-display text-lg font-bold">Rally</span>
            </Link>
          </div>

          <Tabs defaultValue="signin">
            <TabsList className="grid w-full grid-cols-2">
              <TabsTrigger value="signin">{t("auth.tabs.signIn")}</TabsTrigger>
              <TabsTrigger value="signup">{t("auth.tabs.signUp")}</TabsTrigger>
            </TabsList>

            {GOOGLE_SIGN_IN_ENABLED && (
              <>
                <div className="relative mt-6">
                  <GoogleSignInButton onCredential={handleGoogleCredential} />
                  {googleLoading && (
                    <div className="absolute inset-0 flex items-center justify-center rounded-md bg-background/80">
                      <Loader2 className="h-4 w-4 animate-spin" />
                    </div>
                  )}
                </div>

                <div className="my-6 flex items-center gap-3 text-xs text-muted-foreground">
                  <span className="h-px flex-1 bg-border" />
                  {t("auth.orWithEmail")}
                  <span className="h-px flex-1 bg-border" />
                </div>
              </>
            )}

            <TabsContent value="signin" className="space-y-4">
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  handleSignIn();
                }}
              >
                <div className="space-y-2">
                  <Label htmlFor="email-in">{t("auth.fields.email")}</Label>
                  <Input
                    id="email-in"
                    type="email"
                    autoComplete="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="you@example.com"
                  />
                </div>
                <div className="space-y-2">
                  <div className="flex items-center justify-between">
                    <Label htmlFor="pw-in">{t("auth.fields.password")}</Label>
                    <Link
                      to="/forgot-password"
                      className="text-xs text-muted-foreground hover:text-foreground"
                    >
                      {t("auth.forgotPassword")}
                    </Link>
                  </div>
                  <Input
                    id="pw-in"
                    type="password"
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="••••••••"
                  />
                </div>
                <Button type="submit" variant="hero" className="w-full" disabled={loading}>
                  {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("common.signIn")}
                </Button>
              </form>
            </TabsContent>

            <TabsContent value="signup" className="space-y-4">
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  handleSignUp();
                }}
              >
                <div className="space-y-2">
                  <Label htmlFor="name-up">{t("auth.fields.displayName")}</Label>
                  <Input
                    id="name-up"
                    value={displayName}
                    onChange={(e) => setDisplayName(e.target.value)}
                    placeholder={t("auth.fields.displayNamePlaceholder")}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="email-up">{t("auth.fields.email")}</Label>
                  <Input
                    id="email-up"
                    type="email"
                    autoComplete="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="you@example.com"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="pw-up">{t("auth.fields.password")}</Label>
                  <Input
                    id="pw-up"
                    type="password"
                    autoComplete="new-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder={t("auth.fields.passwordPlaceholder")}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="pw-confirm-up">{t("auth.fields.confirmPassword")}</Label>
                  <Input
                    id="pw-confirm-up"
                    type="password"
                    autoComplete="new-password"
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    placeholder={t("auth.fields.passwordPlaceholder")}
                  />
                </div>
                <div className="flex items-start gap-2">
                  <Checkbox
                    id="terms-up"
                    checked={termsAccepted}
                    onCheckedChange={(checked) => setTermsAccepted(checked === true)}
                    className="mt-0.5"
                  />
                  <Label htmlFor="terms-up" className="text-sm font-normal leading-snug">
                    {t("auth.fields.termsPrefix")}{" "}
                    <Link to="/terms" target="_blank" className="underline underline-offset-2 hover:text-foreground">
                      {t("auth.fields.termsLink")}
                    </Link>{" "}
                    {t("auth.fields.termsAnd")}{" "}
                    <Link to="/privacy" target="_blank" className="underline underline-offset-2 hover:text-foreground">
                      {t("auth.fields.privacyLink")}
                    </Link>
                  </Label>
                </div>
                <Button type="submit" variant="hero" className="w-full" disabled={loading}>
                  {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("auth.tabs.signUp")}
                </Button>
              </form>
            </TabsContent>
          </Tabs>

          <p className="mt-6 text-center text-xs text-muted-foreground">
            <Link to="/" className="hover:text-foreground">
              ← {t("common.backToHome")}
            </Link>
          </p>
        </div>
      </div>

      {/* Terms of Service acceptance gate for a brand-new Google sign-in —
          see event-freeze-and-terms-tickets.md's Ticket H. Not a Dialog
          primitive (no such shadcn component exists in this repo yet) — a
          plain overlay is enough for one non-dismissable prompt, and this
          deliberately has no close/outside-click dismissal, only "Accept"
          or "Sign out instead". */}
      {showTermsGate && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/80 p-6 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-2xl border border-border bg-card p-6 shadow-lg">
            <h2 className="font-display text-lg font-bold">{t("auth.termsGate.title")}</h2>
            <p className="mt-2 text-sm text-muted-foreground">{t("auth.termsGate.body")}</p>

            <div className="mt-4 flex items-start gap-2">
              <Checkbox
                id="terms-gate"
                checked={termsGateAccepted}
                onCheckedChange={(checked) => setTermsGateAccepted(checked === true)}
                className="mt-0.5"
              />
              <Label htmlFor="terms-gate" className="text-sm font-normal leading-snug">
                {t("auth.fields.termsPrefix")}{" "}
                <Link to="/terms" target="_blank" className="underline underline-offset-2 hover:text-foreground">
                  {t("auth.fields.termsLink")}
                </Link>{" "}
                {t("auth.fields.termsAnd")}{" "}
                <Link to="/privacy" target="_blank" className="underline underline-offset-2 hover:text-foreground">
                  {t("auth.fields.privacyLink")}
                </Link>
              </Label>
            </div>

            <Button
              variant="hero"
              className="mt-4 w-full"
              disabled={!termsGateAccepted || termsGateLoading}
              onClick={handleAcceptTermsGate}
            >
              {termsGateLoading && <Loader2 className="h-4 w-4 animate-spin" />}
              {t("auth.termsGate.accept")}
            </Button>
            <button
              type="button"
              onClick={handleDeclineTermsGate}
              className="mt-3 w-full text-center text-xs text-muted-foreground hover:text-foreground"
            >
              {t("auth.termsGate.decline")}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
