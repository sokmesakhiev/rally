import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { z } from "zod";
import { Activity, Loader2, Check } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { passwordResetsApi } from "@/lib/api-client";

export const Route = createFileRoute("/forgot-password")({
  head: () => ({
    meta: [
      { title: "Reset your password — Rally" },
      { name: "description", content: "Request a password reset link for your Rally account." },
    ],
  }),
  component: ForgotPasswordPage,
});

const emailSchema = z.string().trim().email("Enter a valid email").max(255);

function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  const handleSubmit = async () => {
    const parsed = emailSchema.safeParse(email);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0].message);
      return;
    }

    setLoading(true);
    try {
      await passwordResetsApi.request(parsed.data);
      setSent(true);
    } catch (e: any) {
      toast.error(e.message ?? "Something went wrong");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <div className="w-full max-w-sm">
        <div className="mb-8 text-center">
          <Link to="/" className="inline-flex items-center gap-2">
            <span className="flex h-8 w-8 items-center justify-center rounded-lg [background-image:var(--gradient-hero)]">
              <Activity className="h-5 w-5 text-primary-foreground" />
            </span>
            <span className="font-display text-lg font-bold">Rally</span>
          </Link>
        </div>

        {sent ? (
          <div className="rounded-2xl border border-border bg-card p-6 text-center">
            <Check className="mx-auto h-8 w-8 text-primary" />
            <h1 className="mt-3 font-display text-xl font-bold">Check your email</h1>
            <p className="mt-2 text-sm text-muted-foreground">
              If an account exists for <strong>{email}</strong>, we've sent a link to reset your
              password. It expires in 2 hours.
            </p>
            <Button asChild variant="outline" className="mt-6 w-full">
              <Link to="/auth">Back to sign in</Link>
            </Button>
          </div>
        ) : (
          <div className="rounded-2xl border border-border bg-card p-6">
            <h1 className="font-display text-xl font-bold">Forgot your password?</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Enter your email and we'll send you a reset link.
            </p>

            <div className="mt-6 space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input
                id="email"
                type="email"
                autoComplete="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                onKeyDown={(e) => e.key === "Enter" && handleSubmit()}
              />
            </div>

            <Button variant="hero" className="mt-4 w-full" onClick={handleSubmit} disabled={loading}>
              {loading && <Loader2 className="h-4 w-4 animate-spin" />}
              Send reset link
            </Button>

            <p className="mt-6 text-center text-xs text-muted-foreground">
              <Link to="/auth" className="hover:text-foreground">← Back to sign in</Link>
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
