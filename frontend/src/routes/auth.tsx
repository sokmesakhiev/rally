import { useState, useEffect } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { Activity, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { GoogleSignInButton } from "@/components/google-sign-in-button";
import { authApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";

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
  const { user, loading: authLoading } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);

  useEffect(() => {
    if (!authLoading && user) {
      navigate({ to: "/dashboard", replace: true });
    }
  }, [user, authLoading, navigate]);

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

  const handleSignIn = async () => {
    if (!validate()) return;
    setLoading(true);
    try {
      await authApi.signin(email, password);
      toast.success(t("auth.welcomeBack"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("auth.errors.signInFailed"));
    } finally {
      setLoading(false);
    }
  };

  const handleSignUp = async () => {
    if (!validate()) return;
    setLoading(true);
    try {
      await authApi.signup(email, password, displayName.trim() || undefined);
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
      await authApi.google(idToken);
      toast.success(t("auth.welcomeBack"));
      navigate({ to: "/dashboard", replace: true });
    } catch (e: any) {
      toast.error(e.message ?? t("auth.errors.signInFailed"));
    } finally {
      setGoogleLoading(false);
    }
  };

  return (
    <div className="flex min-h-screen flex-col bg-background md:flex-row">
      {/* Brand panel */}
      <div className="relative hidden flex-1 flex-col justify-between overflow-hidden p-12 md:flex [background-image:var(--gradient-surface)]">
        <Link to="/" className="flex items-center gap-2">
          <span className="flex h-8 w-8 items-center justify-center rounded-lg [background-image:var(--gradient-hero)]">
            <Activity className="h-5 w-5 text-primary-foreground" />
          </span>
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
              <Button variant="hero" className="w-full" onClick={handleSignIn} disabled={loading}>
                {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                {t("common.signIn")}
              </Button>
            </TabsContent>

            <TabsContent value="signup" className="space-y-4">
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
              <Button variant="hero" className="w-full" onClick={handleSignUp} disabled={loading}>
                {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                {t("auth.tabs.signUp")}
              </Button>
            </TabsContent>
          </Tabs>

          <p className="mt-6 text-center text-xs text-muted-foreground">
            <Link to="/" className="hover:text-foreground">
              ← {t("common.backToHome")}
            </Link>
          </p>
        </div>
      </div>
    </div>
  );
}
