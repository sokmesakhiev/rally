import { useEffect, useRef, useState } from "react";
import QrScanner from "qr-scanner";
import { CameraOff, ScanLine } from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { registrationsApi } from "@/lib/api-client";
import { Button } from "@/components/ui/button";

interface CheckInScannerProps {
  /** Called after a scan successfully checks someone in, so the caller can
   * invalidate/refetch the participants list and update the checked-in
   * count. */
  onCheckedIn: () => void;
}

/** Camera-based QR scanner for organizer check-in at the event door. Scans
 * the raw registration id encoded by RegistrationTicketQR and calls the
 * check-in endpoint directly — no manual search needed for the common case.
 * If the browser denies camera access, or there's no camera at all, this
 * just shows an error and the manual participant list (rendered alongside
 * it by the caller) remains the fallback path. */
export function CheckInScanner({ onCheckedIn }: CheckInScannerProps) {
  const { t } = useTranslation();
  const videoRef = useRef<HTMLVideoElement>(null);
  const scannerRef = useRef<QrScanner | null>(null);
  const processingRef = useRef(false);
  const [active, setActive] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    return () => {
      scannerRef.current?.stop();
      scannerRef.current?.destroy();
      scannerRef.current = null;
    };
  }, []);

  const handleScan = async (registrationId: string) => {
    if (processingRef.current) return;
    processingRef.current = true;
    try {
      const { registration, already_checked_in } = await registrationsApi.checkIn(
        registrationId,
      );
      const name = registration.profile?.display_name || t("checkIn.unnamedParticipant");
      toast.success(
        already_checked_in
          ? t("checkIn.alreadyCheckedInToast", { name })
          : t("checkIn.checkedInToast", { name }),
      );
      onCheckedIn();
    } catch (e: any) {
      toast.error(e.message ?? t("checkIn.scanError"));
    } finally {
      // Debounce so the same badge held in front of the camera doesn't fire
      // a dozen scans before the person pulls it away.
      setTimeout(() => {
        processingRef.current = false;
      }, 1500);
    }
  };

  const start = async () => {
    setError(null);
    if (!videoRef.current) return;
    try {
      const scanner = new QrScanner(videoRef.current, (result) => handleScan(result.data), {
        highlightScanRegion: true,
        highlightCodeOutline: true,
        preferredCamera: "environment",
      });
      scannerRef.current = scanner;
      await scanner.start();
      setActive(true);
    } catch {
      setError(t("checkIn.cameraError"));
      setActive(false);
    }
  };

  const stop = () => {
    scannerRef.current?.stop();
    setActive(false);
  };

  return (
    <div className="rounded-2xl border border-border bg-card p-6">
      <div className="mb-1 flex items-center gap-2">
        <ScanLine className="h-5 w-5 text-muted-foreground" />
        <h2 className="font-semibold">{t("checkIn.scannerTitle")}</h2>
      </div>
      <p className="mb-4 text-sm text-muted-foreground">{t("checkIn.scannerDesc")}</p>

      <div className="relative mx-auto aspect-square max-w-xs overflow-hidden rounded-xl bg-muted">
        <video
          ref={videoRef}
          className={`h-full w-full object-cover ${active ? "block" : "hidden"}`}
          muted
          playsInline
        />
        {!active && (
          <div className="flex h-full items-center justify-center">
            <CameraOff className="h-8 w-8 text-muted-foreground" />
          </div>
        )}
      </div>

      {error && <p className="mt-3 text-center text-sm text-destructive">{error}</p>}

      <div className="mt-4 flex justify-center">
        {active ? (
          <Button variant="outline" size="sm" onClick={stop}>
            {t("checkIn.stopScanning")}
          </Button>
        ) : (
          <Button size="sm" onClick={start}>
            <ScanLine className="h-4 w-4" /> {t("checkIn.startScanning")}
          </Button>
        )}
      </div>
    </div>
  );
}
