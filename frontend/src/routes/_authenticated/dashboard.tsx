import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import {
  CalendarPlus,
  CalendarDays,
  MapPin,
  Users,
  Settings,
  Download,
  Ticket,
  Award,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { registrationsApi, eventsApi } from "@/lib/api-client";
import { PresentedByInline, type PresentedByOrganization } from "@/components/presented-by";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { RegistrationTicketQR } from "@/components/registration-ticket-qr";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { formatDateTime, formatPrice, formatFinishTime, categoryLabel } from "@/lib/event-utils";
import { downloadICS } from "@/lib/ics";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({ meta: [{ title: "Dashboard — Rally" }] }),
  component: Dashboard,
});

interface EventRow {
  id: string;
  title: string;
  description: string | null;
  category: string;
  location: string | null;
  start_at: string;
  end_at: string | null;
  capacity: number | null;
  price_cents: number;
  currency: string;
  is_published: boolean;
  /** Lets a participant check who's behind an event before signing up for
   * another one — see PresentedByInline (#337). */
  organization: PresentedByOrganization | null;
}

function Dashboard() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [tab, setTab] = useState("participating");

  const participating = useQuery({
    queryKey: ["my-registrations", user?.id],
    enabled: !!user,
    queryFn: () => registrationsApi.mine().then((r) => r.registrations),
  });

  const created = useQuery({
    queryKey: ["my-events", user?.id],
    enabled: !!user,
    queryFn: () => eventsApi.my().then((r) => r.events),
  });

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-5xl px-5 py-10">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">{t("dashboard.title")}</h1>
            <p className="mt-1 text-muted-foreground">{t("dashboard.subtitle")}</p>
          </div>
          <Button asChild variant="hero">
            <Link to="/events/new">
              <CalendarPlus className="h-4 w-4" /> {t("dashboard.createEvent")}
            </Link>
          </Button>
        </div>

        <Tabs value={tab} onValueChange={setTab} className="mt-8">
          <TabsList className="grid w-full max-w-md grid-cols-2">
            <TabsTrigger value="participating">
              {t("dashboard.participating")}
              {participating.data ? ` (${participating.data.length})` : ""}
            </TabsTrigger>
            <TabsTrigger value="created">
              {t("dashboard.created")}
              {created.data ? ` (${created.data.length})` : ""}
            </TabsTrigger>
          </TabsList>

          {/* Participating */}
          <TabsContent value="participating" className="mt-6 space-y-4">
            {participating.isLoading && (
              <p className="text-muted-foreground">{t("common.loading")}</p>
            )}
            {participating.isError && (
              <p className="text-sm text-destructive">{t("dashboard.registrationsError")}</p>
            )}
            {participating.data?.length === 0 && (
              <EmptyState
                icon={Ticket}
                title={t("dashboard.emptyParticipatingTitle")}
                desc={t("dashboard.emptyParticipatingDesc")}
                action={
                  <Button asChild variant="outline">
                    <Link to="/events">{t("header.browseEvents")}</Link>
                  </Button>
                }
              />
            )}
            {participating.data?.map((reg) => {
              const ev = reg.event as EventRow | null;
              if (!ev) return null;
              return (
                <div
                  key={reg.id}
                  className="rounded-2xl border border-border bg-card p-5 shadow-[var(--shadow-card)]"
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <div className="flex items-center gap-2">
                        <Badge variant="secondary">{categoryLabel(ev.category)}</Badge>
                        <Badge variant={reg.payment_status === "paid" ? "default" : "outline"}>
                          {ev.price_cents === 0
                            ? t("common.free")
                            : reg.payment_status === "paid"
                              ? t("dashboard.paid")
                              : t("dashboard.paymentDue")}
                        </Badge>
                      </div>
                      <h3 className="mt-2 text-lg font-semibold">{ev.title}</h3>
                      {/* Deciding whether to sign up with this organizer
                          again starts with knowing who they are. */}
                      {ev.organization && (
                        <Link
                          to="/organizers/$slug"
                          params={{ slug: ev.organization.slug }}
                          className="mt-1 inline-flex hover:underline"
                        >
                          <PresentedByInline organization={ev.organization} />
                        </Link>
                      )}
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                      </p>
                      {ev.location && (
                        <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                          <MapPin className="h-4 w-4" /> {ev.location}
                        </p>
                      )}
                      {reg.checked_in_at && (
                        <Badge variant="secondary" className="mt-2">
                          {t("dashboard.checkedIn")}
                        </Badge>
                      )}
                      {reg.finish_time_seconds != null && (
                        <p className="mt-1 text-sm text-muted-foreground">
                          {t("dashboard.yourFinishTime", {
                            time: formatFinishTime(reg.finish_time_seconds),
                          })}
                        </p>
                      )}
                    </div>
                    {reg.payment_status === "unpaid" ? (
                      <Button asChild size="sm">
                        <Link to="/events/$eventId" params={{ eventId: ev.id }}>
                          {t("dashboard.completePayment")}
                        </Link>
                      </Button>
                    ) : (
                      <div className="flex flex-wrap items-center gap-2">
                        {reg.certificate_url && (
                          <Button asChild variant="outline" size="sm">
                            <a href={reg.certificate_url} target="_blank" rel="noreferrer">
                              <Award className="h-4 w-4" /> {t("dashboard.downloadCertificate")}
                            </a>
                          </Button>
                        )}
                        <RegistrationTicketQR registrationId={reg.id} eventTitle={ev.title} />
                        <Button variant="outline" size="sm" onClick={() => downloadICS(ev)}>
                          <Download className="h-4 w-4" /> {t("eventDetail.addToCalendar")}
                        </Button>
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </TabsContent>

          {/* Created */}
          <TabsContent value="created" className="mt-6 space-y-4">
            {created.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}
            {created.isError && (
              <p className="text-sm text-destructive">{t("dashboard.eventsError")}</p>
            )}
            {created.data?.length === 0 && (
              <EmptyState
                icon={CalendarPlus}
                title={t("dashboard.emptyCreatedTitle")}
                desc={t("dashboard.emptyCreatedDesc")}
                action={
                  <Button asChild variant="hero">
                    <Link to="/events/new">{t("dashboard.createEvent")}</Link>
                  </Button>
                }
              />
            )}
            {created.data?.map((ev: any) => {
              const count = ev.registrations_count ?? 0;
              return (
                <div
                  key={ev.id}
                  className="rounded-2xl border border-border bg-card p-5 shadow-[var(--shadow-card)]"
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <div className="flex items-center gap-2">
                        <Badge variant="secondary">{categoryLabel(ev.category)}</Badge>
                        {!ev.is_published && <Badge variant="outline">{t("common.draft")}</Badge>}
                        <Badge variant="outline">{formatPrice(ev.price_cents, ev.currency)}</Badge>
                      </div>
                      <h3 className="mt-2 text-lg font-semibold">{ev.title}</h3>
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                      </p>
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <Users className="h-4 w-4" />{" "}
                        {ev.capacity
                          ? t("dashboard.participantsWithCapacity", {
                              count,
                              capacity: ev.capacity,
                            })
                          : t("dashboard.participantsNoCapacity", { count })}
                      </p>
                    </div>
                    <Button asChild variant="outline" size="sm">
                      <Link to="/dashboard/events/$eventId" params={{ eventId: ev.id }}>
                        <Settings className="h-4 w-4" /> {t("dashboard.manage")}
                      </Link>
                    </Button>
                  </div>
                </div>
              );
            })}
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function EmptyState({
  icon: Icon,
  title,
  desc,
  action,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  desc: string;
  action: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center rounded-2xl border border-dashed border-border py-16 text-center">
      <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-muted text-muted-foreground">
        <Icon className="h-6 w-6" />
      </span>
      <h3 className="mt-4 text-lg font-semibold">{title}</h3>
      <p className="mt-1 max-w-xs text-sm text-muted-foreground">{desc}</p>
      <div className="mt-5">{action}</div>
    </div>
  );
}
