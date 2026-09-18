import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Flag, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { EVENT_REPORT_REASONS, eventsApi, type EventReportReason } from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

/**
 * "Report this event" — the intake for Rally's moderation queue.
 *
 * Reporting is the *only* pre-emptive control on event content: there is no
 * classifier, deliberately, because the four categories Rally refuses to host
 * (political gathering, gambling, violence, discrimination) are also the four
 * with the worst legitimate overlap on a sports platform — boxing, charity
 * casino nights, women-only races, charity runs with a cause. A person reading
 * the page has the context to tell those apart; a model scoring the text
 * doesn't.
 *
 * Three things this component must not do, each for a specific reason:
 *
 *   * **Never show whether an event has already been reported.** The server
 *     returns an identical response for a first report, a duplicate, and an
 *     already-suspended event, so that the endpoint isn't an oracle for
 *     Rally's moderation state. Rendering "already reported" here would hand
 *     back exactly what the API withholds.
 *   * **Never require an account.** The person best placed to report a
 *     gathering they're frightened of may not want one, and requiring it
 *     filters out the reports most worth having. The server rate-limits
 *     anonymous submissions instead.
 *   * **Never promise an outcome.** No count of reports hides anything — a
 *     human reviews and decides. Copy says staff will look, not that anything
 *     will happen.
 */
export function ReportEventDialog({ eventId }: { eventId: string }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState<EventReportReason | null>(null);
  const [details, setDetails] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    if (!reason) {
      setError(t("report.pickReason"));
      return;
    }

    setSubmitting(true);
    setError(null);
    try {
      await eventsApi.report(eventId, reason, details);
      setOpen(false);
      setReason(null);
      setDetails("");
      toast.success(t("report.thanks"));
    } catch (e: any) {
      setError(e.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm" className="text-muted-foreground">
          <Flag className="h-4 w-4" /> {t("report.trigger")}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("report.title")}</DialogTitle>
          <DialogDescription>{t("report.description")}</DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label>{t("report.reasonLabel")}</Label>
            {/* Buttons rather than a <select>: five options is few enough to
                show at once, and each needs a line of explanation that a
                select can't carry. Someone reporting should not have to guess
                which category their concern falls into. */}
            <div className="grid gap-2">
              {EVENT_REPORT_REASONS.map((value) => (
                <button
                  key={value}
                  type="button"
                  onClick={() => {
                    setReason(value);
                    setError(null);
                  }}
                  aria-pressed={reason === value}
                  className={`rounded-lg border px-3 py-2 text-left text-sm transition-colors ${
                    reason === value
                      ? "border-primary bg-primary/5"
                      : "border-border hover:border-border/80"
                  }`}
                >
                  <span className="block font-medium">{t(`report.reason.${value}`)}</span>
                  <span className="block text-xs text-muted-foreground">
                    {t(`report.reasonHint.${value}`)}
                  </span>
                </button>
              ))}
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="report-details">{t("report.detailsLabel")}</Label>
            <Textarea
              id="report-details"
              value={details}
              maxLength={2000}
              onChange={(e) => setDetails(e.target.value)}
              placeholder={t("report.detailsPlaceholder")}
            />
          </div>

          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={submitting}>
            {t("common.cancel")}
          </Button>
          <Button onClick={submit} disabled={submitting}>
            {submitting && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("report.submit")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
