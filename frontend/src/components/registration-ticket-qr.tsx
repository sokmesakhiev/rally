import { useCallback, useEffect, useState } from "react";
import QRCode from "qrcode";
import { Ticket } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

interface RegistrationTicketQRProps {
  registrationId: string;
  eventTitle: string;
  brandColor?: string;
}

/** The attendee-facing counterpart to the organizer's check-in scanner
 * (see check-in-scanner.tsx): a QR code that just encodes this
 * registration's id, so scanning it is a direct, offline-friendly lookup —
 * no need to search a name at the door. Rendered in a dialog rather than
 * inline so a participant's card/list row stays compact. */
export function RegistrationTicketQR({
  registrationId,
  eventTitle,
  brandColor = "#6366f1",
}: RegistrationTicketQRProps) {
  const { t } = useTranslation();
  // A plain useRef isn't enough here: Radix's Dialog defers actually
  // mounting DialogContent into the DOM by one extra render pass after
  // `open` turns true (its Presence primitive sequences the mount through
  // its own useLayoutEffect state machine, to support animate-out on
  // close). An effect keyed on `open` therefore fires a tick before the
  // canvas element exists, so it silently drew into nothing. A callback
  // ref stored in state re-runs the draw exactly when the canvas node
  // itself actually shows up (or goes away), independent of that timing.
  const [canvasEl, setCanvasEl] = useState<HTMLCanvasElement | null>(null);
  const canvasRef = useCallback((node: HTMLCanvasElement | null) => setCanvasEl(node), []);

  useEffect(() => {
    if (!canvasEl) return;
    QRCode.toCanvas(canvasEl, registrationId, {
      width: 220,
      margin: 2,
      color: { dark: brandColor, light: "#ffffff" },
    }).catch((err) => {
      console.error("Failed to render ticket QR code", err);
    });
  }, [canvasEl, registrationId, brandColor]);

  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Ticket className="h-4 w-4" /> {t("registrationTicket.showTicket")}
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-xs">
        <DialogHeader>
          <DialogTitle>{eventTitle}</DialogTitle>
        </DialogHeader>
        <div className="flex flex-col items-center gap-3 py-2">
          <canvas
            ref={canvasRef}
            width={220}
            height={220}
            className="rounded-xl border border-border shadow-sm"
          />
          <p className="text-center text-xs text-muted-foreground">
            {t("registrationTicket.showAtCheckIn")}
          </p>
        </div>
      </DialogContent>
    </Dialog>
  );
}
