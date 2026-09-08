import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import QRCode from "qrcode";
import { Loader2, Smartphone, RefreshCw, Check, AlertCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { eventPlanPaymentsApi, type ApiEventPlanPayment } from "@/lib/api-client";
import { formatPrice } from "@/lib/event-utils";

interface PlanPaymentPanelProps {
  eventId: string;
  plan: string;
  brandColor?: string;
  /** Called once the event is actually published (free tier, or approved payment). */
  onPublished?: () => void;
  /**
   * "publish" (default) is the initial draft → live flow. "change" is
   * picking a different plan on an already-published event (see
   * registration-engagement-tickets.md's "change event plan" work) — same
   * endpoint, same polling, just different success copy since the event
   * isn't newly "published" in that case.
   */
  mode?: "publish" | "change";
}

function useCountdown(expiresAt: string | null) {
  // null = "not yet known" (payment hasn't loaded, or we haven't computed a
  // real value yet) — deliberately distinct from 0 ("genuinely expired").
  // A useState initializer only runs on this component's very first render,
  // which happens before `payment`/`expiresAt` has loaded — defaulting
  // straight to 0 there means a perfectly fresh QR briefly renders as
  // "expired" (skipping the QR canvas entirely) for one render, until the
  // effect below corrects it a tick later. Since the QR-drawing effect in
  // the parent only depends on `payment?.qr_string` (which doesn't change
  // between that first render and the corrected one), the canvas never gets
  // drawn once it does appear — it just sits there blank.
  const [remaining, setRemaining] = useState<number | null>(null);

  useEffect(() => {
    if (!expiresAt) {
      setRemaining(null);
      return;
    }
    const update = () => setRemaining(Math.max(0, new Date(expiresAt).getTime() - Date.now()));
    update(); // compute immediately — don't wait for the first interval tick
    const interval = setInterval(update, 1000);
    return () => clearInterval(interval);
  }, [expiresAt]);

  const minutes = remaining != null ? Math.floor(remaining / 60000) : 0;
  const seconds = remaining != null ? Math.floor((remaining % 60000) / 1000) : 0;
  return {
    remaining,
    label: remaining != null ? `${minutes}:${seconds.toString().padStart(2, "0")}` : "…",
  };
}

export function PlanPaymentPanel({
  eventId,
  plan,
  brandColor = "#6366f1",
  onPublished,
  mode = "publish",
}: PlanPaymentPanelProps) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [planPaymentId, setPlanPaymentId] = useState<string | null>(null);
  const [publishedDirectly, setPublishedDirectly] = useState(false);
  // Guards against React StrictMode's dev-only double-invocation of effects:
  // both invocations read the same (not-yet-re-rendered) startPublish.isPending
  // closure, so that alone doesn't stop a second `mutate()` call — which was
  // creating two separate EventPlanPayment records per plan selection. A ref
  // survives the double-invoke on the same mount but resets on a genuine
  // remount (picking a different plan unmounts/remounts this component), so
  // it still fires once for each real plan selection.
  const startedForPlanRef = useRef<string | null>(null);
  // Tracked separately from startPublish.isPending/isError — deliberately NOT
  // reused from the mutation object below. Once the double-POST guard above
  // ensures mutate() only ever fires from the *first* of StrictMode's two
  // synthetic effect passes, that first pass's bookkeeping gets torn down by
  // the immediately-following synthetic cleanup, and startPublish.isPending
  // never flips back to false even though the request completes successfully
  // (confirmed via debug logging: planPaymentId gets set correctly via
  // onSuccess's plain setState, but isPending stays stuck true forever,
  // leaving the panel stuck on the "Preparing your plan..." spinner). Plain
  // useState isn't affected by that subscription-teardown quirk, so we drive
  // the loading/error UI off state we set ourselves instead of trusting the
  // mutation's own reactive flags.
  const [isStartingPublish, setIsStartingPublish] = useState(true);
  const [startError, setStartError] = useState<Error | null>(null);

  // All three callbacks are declared at the *hook* level (useMutation's own
  // options), not passed per-call to mutate(). TanStack Query re-syncs
  // hook-level options via observer.setOptions() on every render — including
  // React StrictMode's dev-only synthetic second effect pass — so they stay
  // wired no matter which pass actually invoked mutate(). Per-call callbacks
  // (the second argument to .mutate()) are captured once at call time and,
  // confirmed via debug logging, never fired when mutate() was invoked from
  // the first (later torn-down) of StrictMode's two synthetic passes: onSuccess
  // reliably set planPaymentId, but a per-call onSettled never ran, leaving
  // isStartingPublish stuck true forever even though the request had
  // succeeded. Keeping everything hook-level avoids that gap entirely.
  const startPublish = useMutation({
    mutationFn: () => eventPlanPaymentsApi.create(eventId, plan),
    onSuccess: (res) => {
      // Free tier (or re-picking an already-paid plan) publishes immediately
      // with no plan_payment to poll.
      if (res.event) {
        setPublishedDirectly(true);
        return;
      }
      if (res.plan_payment) setPlanPaymentId(res.plan_payment.id);
    },
    onError: (err) => setStartError(err as Error),
    onSettled: () => setIsStartingPublish(false),
  });

  function runStartPublish() {
    setIsStartingPublish(true);
    setStartError(null);
    startPublish.mutate();
  }

  useEffect(() => {
    if (startedForPlanRef.current === plan) return;
    if (!planPaymentId && !publishedDirectly) {
      startedForPlanRef.current = plan;
      runStartPublish();
    } else {
      setIsStartingPublish(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [plan]);

  const statusQuery = useQuery({
    queryKey: ["plan-payment-status", planPaymentId],
    queryFn: () => eventPlanPaymentsApi.status(planPaymentId!),
    enabled: !!planPaymentId,
    refetchInterval: (query) => {
      const p = query.state.data?.plan_payment as ApiEventPlanPayment | undefined;
      return p && p.status === "pending" ? 4000 : false;
    },
  });

  const payment = statusQuery.data?.plan_payment;

  const { label: countdownLabel, remaining } = useCountdown(payment?.expires_at ?? null);

  useEffect(() => {
    if (publishedDirectly || payment?.status === "paid") {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      queryClient.invalidateQueries({ queryKey: ["my-events"] });
      onPublished?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [publishedDirectly, payment?.status]);

  useEffect(() => {
    if (payment?.qr_string && canvasRef.current) {
      QRCode.toCanvas(canvasRef.current, payment.qr_string, {
        width: 220,
        margin: 2,
        color: { dark: "#1a1a2e", light: "#ffffff" },
      }).catch((err) => console.error("Failed to render plan payment QR code", err));
    }
  }, [payment?.qr_string]);

  function regenerate() {
    setPlanPaymentId(null);
    setPublishedDirectly(false);
    startPublish.reset();
    runStartPublish();
  }

  if (publishedDirectly) {
    return (
      <div className="flex flex-col items-center gap-2 py-6 text-center">
        <span className="flex h-10 w-10 items-center justify-center rounded-full bg-primary/10">
          <Check className="h-5 w-5" style={{ color: brandColor }} />
        </span>
        <p className="font-medium">
          {mode === "change"
            ? t("planPaymentPanel.planChanged")
            : t("planPaymentPanel.eventPublished")}
        </p>
        <p className="text-sm text-muted-foreground">
          {mode === "change"
            ? t("planPaymentPanel.planChangeApplied")
            : t("planPaymentPanel.nowVisible")}
        </p>
      </div>
    );
  }

  if (isStartingPublish || (planPaymentId && statusQuery.isLoading && !payment)) {
    return (
      <div className="flex flex-col items-center gap-3 py-8">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        <p className="text-sm text-muted-foreground">{t("planPaymentPanel.preparingPlan")}</p>
      </div>
    );
  }

  if (startError) {
    return (
      <div className="flex flex-col items-center gap-3 py-6 text-center">
        <AlertCircle className="h-6 w-6 text-destructive" />
        <p className="text-sm text-muted-foreground">
          {startError.message || t("planPaymentPanel.startError")}
        </p>
        <Button variant="outline" size="sm" onClick={regenerate}>
          <RefreshCw className="h-4 w-4" /> {t("common.tryAgain")}
        </Button>
      </div>
    );
  }

  if (!payment) return null;

  if (payment.status === "paid") {
    return (
      <div className="flex flex-col items-center gap-2 py-6 text-center">
        <span className="flex h-10 w-10 items-center justify-center rounded-full bg-primary/10">
          <Check className="h-5 w-5" style={{ color: brandColor }} />
        </span>
        <p className="font-medium">
          {mode === "change"
            ? t("planPaymentPanel.paymentReceivedChange")
            : t("planPaymentPanel.paymentReceived")}
        </p>
        <p className="text-sm text-muted-foreground">
          {t("planPaymentPanel.paidMessage", {
            amount: formatPrice(payment.amount_cents, payment.currency),
          })}
        </p>
      </div>
    );
  }

  if (payment.status === "expired" || (payment.status === "pending" && remaining === 0)) {
    return (
      <div className="flex flex-col items-center gap-3 py-6 text-center">
        <p className="text-sm text-muted-foreground">{t("paymentPanel.qrExpired")}</p>
        <Button variant="outline" size="sm" onClick={regenerate}>
          <RefreshCw className="h-4 w-4" /> {t("paymentPanel.generateNewQr")}
        </Button>
      </div>
    );
  }

  if (payment.status === "declined" || payment.status === "cancelled") {
    return (
      <div className="flex flex-col items-center gap-3 py-6 text-center">
        <AlertCircle className="h-6 w-6 text-destructive" />
        <p className="text-sm text-muted-foreground">
          {t("paymentPanel.paymentStatusMessage", {
            status: t(`paymentPanel.status.${payment.status}`),
          })}
        </p>
        <Button variant="outline" size="sm" onClick={regenerate}>
          <RefreshCw className="h-4 w-4" /> {t("common.tryAgain")}
        </Button>
      </div>
    );
  }

  // pending — show the scannable QR
  return (
    <div className="flex flex-col items-center gap-4 py-2 text-center">
      <div>
        <p className="font-medium">{t("paymentPanel.scanInstructions")}</p>
        <p className="text-sm text-muted-foreground">
          {t("paymentPanel.amountExpiresIn", {
            amount: formatPrice(payment.amount_cents, payment.currency),
            time: countdownLabel,
          })}
        </p>
      </div>

      <canvas
        ref={canvasRef}
        width={220}
        height={220}
        className="rounded-xl border border-border shadow-sm"
      />

      {payment.abapay_deeplink && (
        <Button
          asChild
          style={{ backgroundColor: brandColor }}
          className="text-white hover:opacity-90"
        >
          <a href={payment.abapay_deeplink}>
            <Smartphone className="h-4 w-4" /> {t("paymentPanel.openAbaMobile")}
          </a>
        </Button>
      )}

      <p className="text-xs text-muted-foreground">
        {mode === "change"
          ? t("planPaymentPanel.autoApplyNote")
          : t("planPaymentPanel.autoPublishNote")}
      </p>
    </div>
  );
}
