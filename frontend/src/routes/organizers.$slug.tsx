import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  CalendarDays,
  MapPin,
  Building2,
  Globe,
  Mail,
  Phone,
  Users,
  Trophy,
  Clock,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { organizerApi, type ApiOrganizerEvent } from "@/lib/api-client";
import { SiteHeader } from "@/components/site-header";
import { VerifiedBadge } from "@/components/presented-by";
import { formatPrice, formatDate, categoryLabel } from "@/lib/event-utils";
import { Badge } from "@/components/ui/badge";

export const Route = createFileRoute("/organizers/$slug")({
  // English only, matching the existing convention that route meta isn't
  // run through t() — see the i18n notes in CLAUDE.md.
  head: () => ({ meta: [{ title: "Organizer — Rally" }] }),
  component: OrganizerPage,
});

function OrganizerPage() {
  const { slug } = Route.useParams();
  const { t } = useTranslation();

  const query = useQuery({
    queryKey: ["organizer", slug],
    queryFn: () => organizerApi.get(slug).then((r) => r.organizer),
    retry: false,
  });

  const organizer = query.data;

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />

      {/* The organizer's own banner. An event's banner belongs to the event —
          the two brandings live in different places and never compete. */}
      {organizer?.banner_url && (
        <div className="relative h-44 w-full overflow-hidden md:h-60">
          <img
            src={organizer.banner_url}
            alt={organizer.name}
            className="h-full w-full object-cover"
          />
          <div className="absolute inset-0 bg-gradient-to-t from-background/80 to-transparent" />
        </div>
      )}

      <main className="mx-auto max-w-3xl px-5 py-10">
        {query.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}

        {/* A suspended organizer 404s server-side, so this covers both "no
            such organizer" and "no longer available" without leaking which. */}
        {query.isError && (
          <div className="rounded-2xl border border-border bg-muted/30 p-10 text-center">
            <Building2 className="mx-auto h-8 w-8 text-muted-foreground" />
            <p className="mt-4 text-lg font-semibold">{t("organizerPage.notFoundTitle")}</p>
            <p className="mt-2 text-sm text-muted-foreground">
              {t("organizerPage.notFoundDesc")}
            </p>
          </div>
        )}

        {organizer && (
          <>
            <div className="flex flex-wrap items-start gap-4">
              {organizer.logo_url ? (
                <img
                  src={organizer.logo_url}
                  alt={organizer.name}
                  className="h-20 w-20 shrink-0 rounded-2xl border border-border object-cover"
                />
              ) : (
                <div className="flex h-20 w-20 shrink-0 items-center justify-center rounded-2xl bg-muted">
                  <Building2 className="h-8 w-8 text-muted-foreground" />
                </div>
              )}

              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <h1
                    className="font-display text-3xl font-bold"
                    style={organizer.brand_color ? { color: organizer.brand_color } : undefined}
                  >
                    {organizer.name}
                  </h1>
                  <VerifiedBadge verified={organizer.verified} />
                </div>

                {organizer.description && (
                  <p className="mt-3 whitespace-pre-line text-muted-foreground">
                    {organizer.description}
                  </p>
                )}
              </div>
            </div>

            <TrustSignals
              memberSince={organizer.member_since}
              eventsRun={organizer.events_run}
              participantsHosted={organizer.participants_hosted}
            />

            <ContactLinks organizer={organizer} />

            <EventSection
              title={t("organizerPage.upcoming")}
              events={organizer.upcoming_events}
              emptyLabel={t("organizerPage.noUpcoming")}
            />

            {organizer.past_events.length > 0 && (
              <EventSection title={t("organizerPage.past")} events={organizer.past_events} />
            )}
          </>
        )}
      </main>
    </div>
  );
}

/** Social proof that this is a real, established organizer. `events_run`
 * counts finished events only — fifty upcoming and none delivered is not a
 * track record. */
function TrustSignals({
  memberSince,
  eventsRun,
  participantsHosted,
}: {
  memberSince: string;
  eventsRun: number;
  participantsHosted: number;
}) {
  const { t } = useTranslation();

  const items = [
    { icon: Clock, value: formatDate(memberSince), label: t("organizerPage.memberSince") },
    { icon: Trophy, value: String(eventsRun), label: t("organizerPage.eventsRun") },
    {
      icon: Users,
      value: participantsHosted.toLocaleString(),
      label: t("organizerPage.participantsHosted"),
    },
  ];

  return (
    <div className="mt-8 grid gap-3 sm:grid-cols-3">
      {items.map(({ icon: Icon, value, label }) => (
        <div key={label} className="rounded-2xl border border-border p-4">
          <Icon className="h-4 w-4 text-muted-foreground" />
          <p className="mt-2 text-lg font-semibold">{value}</p>
          <p className="text-xs text-muted-foreground">{label}</p>
        </div>
      ))}
    </div>
  );
}

function ContactLinks({
  organizer,
}: {
  organizer: {
    website: string | null;
    contact_email: string | null;
    contact_phone: string | null;
    facebook_url: string | null;
    instagram_url: string | null;
    telegram_url: string | null;
  };
}) {
  const links = [
    { icon: Globe, href: organizer.website, label: organizer.website },
    {
      icon: Mail,
      href: organizer.contact_email ? `mailto:${organizer.contact_email}` : null,
      label: organizer.contact_email,
    },
    {
      icon: Phone,
      href: organizer.contact_phone ? `tel:${organizer.contact_phone}` : null,
      label: organizer.contact_phone,
    },
    { icon: Globe, href: organizer.facebook_url, label: "Facebook" },
    { icon: Globe, href: organizer.instagram_url, label: "Instagram" },
    { icon: Globe, href: organizer.telegram_url, label: "Telegram" },
  ].filter((l) => l.href);

  if (links.length === 0) return null;

  return (
    <div className="mt-6 flex flex-wrap gap-2">
      {links.map(({ icon: Icon, href, label }) => (
        <a
          key={href!}
          href={href!}
          target="_blank"
          rel="noreferrer noopener"
          className="inline-flex items-center gap-1.5 rounded-full border border-border px-3 py-1.5 text-sm transition-colors hover:bg-muted/40"
        >
          <Icon className="h-3.5 w-3.5" />
          <span className="max-w-48 truncate">{label}</span>
        </a>
      ))}
    </div>
  );
}

function EventSection({
  title,
  events,
  emptyLabel,
}: {
  title: string;
  events: ApiOrganizerEvent[];
  emptyLabel?: string;
}) {
  if (events.length === 0 && !emptyLabel) return null;

  return (
    <section className="mt-10">
      <h2 className="font-display text-xl font-semibold">{title}</h2>

      {events.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">{emptyLabel}</p>
      ) : (
        <ul className="mt-4 space-y-3">
          {events.map((event) => (
            <li key={event.id}>
              <Link
                to="/events/$eventId"
                params={{ eventId: event.id }}
                className="flex items-center gap-4 rounded-2xl border border-border p-4 transition-colors hover:bg-muted/40"
              >
                {event.banner_url && (
                  <img
                    src={event.banner_url}
                    alt={event.title}
                    className="hidden h-16 w-24 shrink-0 rounded-xl object-cover sm:block"
                  />
                )}
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant="secondary">{categoryLabel(event.category)}</Badge>
                    <Badge variant="outline">{formatPrice(event.price_cents, event.currency)}</Badge>
                  </div>
                  <p className="mt-1.5 truncate font-medium">{event.title}</p>
                  <p className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
                    <span className="inline-flex items-center gap-1">
                      <CalendarDays className="h-3.5 w-3.5" />
                      {formatDate(event.start_at)}
                    </span>
                    {event.location && (
                      <span className="inline-flex items-center gap-1">
                        <MapPin className="h-3.5 w-3.5" />
                        <span className="truncate">{event.location}</span>
                      </span>
                    )}
                  </p>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
