import { Link } from "@tanstack/react-router";
import { BadgeCheck, Building2 } from "lucide-react";
import { useTranslation } from "react-i18next";

/**
 * "Presented by <organization>" — the link from an event to whoever is
 * running it (organization-identity-tickets.md's Ticket H, #337).
 *
 * Deliberately kept apart from the event's own hero branding. Per the up-front
 * scoping decision, event branding and organizer branding are both shown, in
 * different places, with no inheritance and no override: the banner is the
 * event's, this block is the organizer's. Rendering the organizer's logo into
 * the hero would blur exactly the distinction this feature exists to draw.
 *
 * The verified badge is the load-bearing trust signal, so it renders
 * identically here, on event cards, on the organizer page, and in a
 * participant's registration list — and an unverified organizer is visibly
 * unverified rather than merely missing a badge.
 */
export interface PresentedByOrganization {
  slug: string;
  name: string;
  logo_url: string | null;
  verified: boolean;
}

export function VerifiedBadge({ verified }: { verified: boolean }) {
  const { t } = useTranslation();

  if (verified) {
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
        <BadgeCheck className="h-3.5 w-3.5" />
        {t("presentedBy.verified")}
      </span>
    );
  }

  // Shown rather than omitted: "we haven't verified this organizer" is
  // information a participant deciding whether to pay should actually see.
  return (
    <span className="inline-flex items-center rounded-full border border-border px-2 py-0.5 text-xs text-muted-foreground">
      {t("presentedBy.unverified")}
    </span>
  );
}

function OrganizationLogo({
  organization,
  size,
}: {
  organization: PresentedByOrganization;
  size: "sm" | "md";
}) {
  const box = size === "sm" ? "h-6 w-6" : "h-10 w-10";

  if (!organization.logo_url) {
    return (
      <div
        className={`${box} flex shrink-0 items-center justify-center rounded-full bg-muted text-muted-foreground`}
      >
        <Building2 className={size === "sm" ? "h-3.5 w-3.5" : "h-5 w-5"} />
      </div>
    );
  }

  return (
    <img
      src={organization.logo_url}
      alt={organization.name}
      className={`${box} shrink-0 rounded-full border border-border object-cover`}
    />
  );
}

/** Full block, for an event's detail page. */
export function PresentedBy({ organization }: { organization: PresentedByOrganization | null }) {
  const { t } = useTranslation();

  if (!organization) return null;

  return (
    <Link
      to="/organizers/$slug"
      params={{ slug: organization.slug }}
      className="mt-6 flex items-center gap-3 rounded-2xl border border-border p-4 transition-colors hover:bg-muted/40"
    >
      <OrganizationLogo organization={organization} size="md" />
      <div className="min-w-0">
        <p className="text-xs text-muted-foreground">{t("presentedBy.label")}</p>
        <p className="flex flex-wrap items-center gap-2 font-medium">
          <span className="truncate">{organization.name}</span>
          <VerifiedBadge verified={organization.verified} />
        </p>
      </div>
    </Link>
  );
}

/**
 * Compact variant for event cards and registration lists. Not a link — these
 * usually sit inside one already, and nesting anchors is invalid HTML.
 */
export function PresentedByInline({
  organization,
}: {
  organization: PresentedByOrganization | null;
}) {
  if (!organization) return null;

  return (
    <span className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
      <OrganizationLogo organization={organization} size="sm" />
      <span className="truncate">{organization.name}</span>
      {organization.verified && <BadgeCheck className="h-3.5 w-3.5 shrink-0 text-primary" />}
    </span>
  );
}
