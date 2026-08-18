import { useEffect, useRef, useState } from "react";
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
  const canvasRef = useRef<HTMLCanvasElement>(null);
  // Radix's DialogContent isn't mounted into the DOM until the dialog is
  // actually open (it's unmounted, not just hidden, while closed) — so
  // canvasRef.current was still null the one time this effect ran on
  // mount, and the canvas never got drawn into. Tracking `open` ourselves
  // and depending on it here re-runs the draw once the canvas element
  // actually exists.
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open || !canvasRef.current) return;
    QRCode.toCanvas(canvasRef.current, registrationId, {
      width: 220,
      margin: 2,
      color: { dark: brandColor, light: "#ffffff" },
    });
  }, [open, registrationId, brandColor]);

  return (
    <Dialog open={open} onOpenChange={setOpen}>
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
