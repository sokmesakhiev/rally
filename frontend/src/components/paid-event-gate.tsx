/**
 * PaidEventGate — the paid/free toggle, plus the "your account needs to be
 * verified" prompt shown in its place when the organizer isn't verified yet.
 *
 * Shared by the create form (events.new.tsx) and the edit form
 * (event-details-editor.tsx) so the two can't drift — the rule is identical
 * in both places, and so is the server-side check that actually enforces it
 * (Api::V1::EventsController#reject_unverified_paid_event!, which returns
 * `code: "verification_required"`). This is purely an affordance: it exists
 * so an organizer finds out *before* filling in a whole form, not as the
 * security boundary. Never treat it as one — `verified` comes from the JWT
 * payload the client holds and is trivially editable client-side.
 *
 * Deliberately gates on `user.verified` (admin-granted, see User#verified?),
 * NOT `user.email_verified` (self-service, proves nothing about identity).
 */
import { ShieldAlert } from "lucide-react";
import { useTranslation } from "react-i18next";

import { Switch } from "@/components/ui/switch";

export function PaidEventGate({
  verified,
  isPaid,
  onIsPaidChange,
  /**
   * True when the event already has a price. An event created while the
   * organizer was verified stays editable even if verification is later
   * revoked — mirrors the server, which only gates the free → paid
   * transition (see User#unverify!). Without this the edit form would lock
   * an organizer out of their own already-live paid event.
   */
  alreadyPaid = false,
}: {
  verified: boolean;
  isPaid: boolean;
  onIsPaidChange: (next: boolean) => void;
  alreadyPaid?: boolean;
}) {
  const { t } = useTranslation();

  if (!verified && !alreadyPaid) {
    return (
      <div className="rounded-xl border border-border bg-muted/40 p-4">
        <div className="flex items-start gap-3">
          <ShieldAlert className="mt-0.5 h-5 w-5 flex-shrink-0 text-muted-foreground" />
          <div>
            <p className="font-medium">{t("eventForm.paidEvent")}</p>
            <p className="mt-1 text-sm text-muted-foreground">
              {t("eventForm.verificationRequired")}
            </p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex items-center justify-between rounded-xl border border-border p-4">
      <div>
        <p className="font-medium">{t("eventForm.paidEvent")}</p>
        <p className="text-sm text-muted-foreground">{t("eventForm.paidEventDesc")}</p>
      </div>
      <Switch checked={isPaid} onCheckedChange={onIsPaidChange} />
    </div>
  );
}
