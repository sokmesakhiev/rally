import { useState } from "react";
import { Loader2, Mail } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/lib/use-auth";
import { emailVerificationsApi } from "@/lib/api-client";

export function VerifyEmailBanner() {
  const { user } = useAuth();
  const { t } = useTranslation();
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);

  // A phone-only guest's email is an auto-generated placeholder (see
  // Registrations::GuestCheckout / ApiUser.email_auto_generated) — asking
  // them to "verify" an address that was never theirs to begin with would
  // be actively misleading. AddRealEmailBanner covers that case instead.
  if (!user || user.email_verified || user.email_auto_generated) return null;

  const resend = async () => {
    setSending(true);
    try {
      await emailVerificationsApi.resend();
      setSent(true);
      toast.success(t("verifyEmailBanner.sentToast"));
    } catch (e: any) {
      toast.error(e.message ?? t("verifyEmailBanner.sendError"));
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="flex flex-wrap items-center justify-center gap-3 bg-amber-500/10 px-4 py-2 text-center text-sm text-amber-700 dark:text-amber-400">
      <span className="flex items-center gap-1.5">
        <Mail className="h-4 w-4" /> {t("verifyEmailBanner.message", { email: user.email })}
      </span>
      <Button
        size="sm"
        variant="outline"
        className="h-7 border-amber-500/40 text-xs"
        onClick={resend}
        disabled={sending || sent}
      >
        {sending && <Loader2 className="h-3 w-3 animate-spin" />}
        {sent ? t("verifyEmailBanner.sent") : t("verifyEmailBanner.resend")}
      </Button>
    </div>
  );
}
