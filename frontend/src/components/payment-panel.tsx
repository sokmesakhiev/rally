import { useCallback, useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import QRCode from "qrcode";
import { Loader2, Smartphone, RefreshCw, Check, AlertCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { paymentsApi, type ApiPayment, type GuestContact } from "@/lib/api-client";
import { formatPrice } from "@/lib/event-utils";

interface PaymentPanelProps {
  registrationId: string;
  brandColor?: string;
  /** Only needed when rendered for a signed-out guest — see
   * registrationsApi.create/paymentsApi.create. Omit entirely for a
   * signed-in user; the session already authorizes the payment. */
  guestContact?: GuestContact;
  /** Called once the payment status becomes "approved". */
  onPaid?: () => void;
}

function useCountdown(expiresAt: string | null) {
  const [remaining, setRemaining] = useState(() =>
    expiresAt ? Math.max(0, new Date(expiresAt).getTime() - Date.now()) : 0,
  );

  useEffect(() => {
    if (!expiresAt) return;
    const interval = setInterval(() => {
      setRemaining(Math.max(0, new Date(expiresAt).getTime() - Date.now()));
    }, 1000);
    return () => clearInterval(interval);
  }, [expiresAt]);

  const minutes = Math.floor(remaining / 60000);
  const seconds = Math.floor((remaining % 60000) / 1000);
  return { remaining, label: `${minutes}:${seconds.toString().padStart(2, "0")}` };
}

export function PaymentPanel({
  registrationId,
  brandColor = "#6366f1",
  guestContact,
  onPaid,
}: PaymentPanelProps) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  // A plain useRef isn't reliable here: if the effect that draws the QR
  // runs before React has actually attached the canvas to the DOM (e.g.
  // this panel remounting as part of a parent re-render), canvasRef.current
  // is still null and the draw call is silently skipped — the box renders
  // but stays empty forever, since the effect never reruns just because a
  // ref value changed. A callback ref stored in state re-runs the draw
  // exactly when the canvas node itself shows up (or goes away) — same fix
  // RegistrationTicketQR uses for the same class of timing issue.
  const [canvasEl, setCanvasEl] = useState<HTMLCanvasElement | null>(null);
  const canvasRef = useCallback((node: HTMLCanvasElement | null) => setCanvasEl(node), []);
  const [qrError, setQrError] = useState(false);
  const [paymentId, setPaymentId] = useState<string | null>(null);

  const createPayment = useMutation({
    mutationFn: () => paymentsApi.create(registrationId, guestContact),
    onSuccess: (res) => setPaymentId(res.payment.id),
  });

  // Auto-generate a QR as soon as the panel mounts.
  useEffect(() => {
    if (!paymentId && !createPayment.isPending && !createPayment.isError) {
      createPayment.mutate();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const statusQuery = useQuery({
    queryKey: ["payment-status", paymentId],
    queryFn: () => paymentsApi.status(paymentId!, guestContact),
    enabled: !!paymentId,
    refetchInterval: (query) => {
      const p = query.state.data?.payment as ApiPayment | undefined;
      return p && p.status === "pending" ? 4000 : false;
    },
  });

  const payment = statusQuery.data?.payment;
  const { label: countdownLabel, remaining } = useCountdown(payment?.expires_at ?? null);

  useEffect(() => {
    if (payment?.status === "approved") {
      queryClient.invalidateQueries({ queryKey: ["my-reg"] });
      queryClient.invalidateQueries({ queryKey: ["my-registrations"] });
      onPaid?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [payment?.status]);

  useEffect(() => {
    if (!canvasEl || !payment?.qr_string) return;

    setQrError(false);
    QRCode.toCanvas(canvasEl, payment.qr_string, {
      width: 220,
      margin: 2,
      color: { dark: "#1a1a2e", light: "#ffffff" },
    }).catch((err) => {
      // Previously swallowed entirely, which meant an encoding failure (or
      // any other draw error) left the box permanently blank with no way
      // to tell why — surface it so it's diagnosable, and let the person
      // still pay via the ABA Mobile deep link / regenerate instead.
      console.error("Failed to render payment QR code", err);
      setQrError(true);
    });
  }, [canvasEl, payment?.qr_string]);

  function regenerate() {
    setPaymentId(null);
    setQrError(false);
    createPayment.reset();
    createPayment.mutate();
  }

  if (createPayment.isPending || (paymentId && statusQuery.isLoading && !payment)) {
    return (
      <div className="flex flex-col items-center gap-3 py-8">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        <p className="text-sm text-muted-foreground">{t("paymentPanel.generatingQr")}</p>
      </div>
    );
  }

  if (createPayment.isError) {
    return (
      <div className="flex flex-col items-center gap-3 py-6 text-center">
        <AlertCircle className="h-6 w-6 text-destructive" />
        <p className="text-sm text-muted-foreground">
          {(createPayment.error as any)?.message ?? t("paymentPanel.startError")}
        </p>
        <Button variant="outline" size="sm" onClick={regenerate}>
          <RefreshCw className="h-4 w-4" /> {t("common.tryAgain")}
        </Button>
      </div>
    );
  }

  if (!payment) return null;

  if (payment.status === "approved") {
    return (
      <div className="flex flex-col items-center gap-2 py-6 text-center">
        <span className="flex h-10 w-10 items-center justify-center rounded-full bg-primary/10">
          <Check className="h-5 w-5" style={{ color: brandColor }} />
        </span>
        <p className="font-medium">{t("paymentPanel.paymentReceived")}</p>
        <p className="text-sm text-muted-foreground">
          {t("paymentPanel.paidMessage", {
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

      {qrError ? (
        <div className="flex h-[220px] w-[220px] flex-col items-center justify-center gap-2 rounded-xl border border-border bg-muted/30 p-4 text-center">
          <AlertCircle className="h-5 w-5 text-destructive" />
          <p className="text-xs text-muted-foreground">{t("paymentPanel.qrRenderError")}</p>
        </div>
      ) : (
        <canvas
          ref={canvasRef}
          width={220}
          height={220}
          className="rounded-xl border border-border shadow-sm"
        />
      )}

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

      {qrError && (
        <Button variant="outline" size="sm" onClick={regenerate}>
          <RefreshCw className="h-4 w-4" /> {t("paymentPanel.generateNewQr")}
        </Button>
      )}

      <p className="text-xs text-muted-foreground">{t("paymentPanel.autoConfirmNote")}</p>
    </div>
  );
}
