import { useTranslation } from "react-i18next";
import { ShieldCheck } from "lucide-react";
import type { RefundPolicy } from "@/lib/api-client";
import { cn } from "@/lib/utils";

interface RefundPolicyNoticeProps {
  policy: RefundPolicy | null;
  className?: string;
}

/**
 * Shows a host's refund policy in plain language, at checkout and on the
 * event page.
 *
 * Renders nothing when `policy` is null. That is not the same as an empty
 * tier list: null means the host never set a policy, so refunds remain a
 * conversation with them, and inventing a notice would be claiming something
 * on their behalf. An empty `tiers` array is a real, deliberate "no refunds"
 * and does get shown.
 *
 * See platform-payments-tickets.md Ticket D.
 */
export function RefundPolicyNotice({ policy, className }: RefundPolicyNoticeProps) {
  const { t } = useTranslation();

  if (!policy) return null;

  return (
    <div className={cn("rounded-lg border border-border bg-muted/40 px-4 py-3 text-xs", className)}>
      <p className="flex items-center gap-1.5 font-medium text-foreground">
        <ShieldCheck className="h-3.5 w-3.5" aria-hidden="true" />
        {t("refundPolicy.title")}
      </p>

      {policy.tiers.length === 0 ? (
        <p className="mt-1.5 text-muted-foreground">{t("refundPolicy.nonRefundable")}</p>
      ) : (
        <ul className="mt-1.5 space-y-1 text-muted-foreground">
          {policy.tiers.map((tier) => (
            <li key={tier.hours_before}>
              {tier.refund_percent === 100
                ? t("refundPolicy.tierFull", { lead: formatLeadTime(tier.hours_before, t) })
                : t("refundPolicy.tierPartial", {
                    percent: tier.refund_percent,
                    lead: formatLeadTime(tier.hours_before, t),
                  })}
            </li>
          ))}
          {/* The implicit final step. The server never stores a 0% tier, but a
              participant reading the list needs to know what happens after
              the last cutoff — otherwise the policy looks open-ended. */}
          <li>{t("refundPolicy.tierNone")}</li>
        </ul>
      )}
    </div>
  );
}

/**
 * Hours are the storage unit because they express both "48 hours" and
 * "7 days" without a second column. Whole days read better than "168 hours",
 * so convert back when it divides evenly.
 */
function formatLeadTime(hours: number, t: (key: string, opts?: object) => string): string {
  if (hours >= 24 && hours % 24 === 0) {
    return t("refundPolicy.days", { count: hours / 24 });
  }
  return t("refundPolicy.hours", { count: hours });
}
