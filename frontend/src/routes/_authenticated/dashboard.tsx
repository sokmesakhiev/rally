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
} from "lucide-react";
import { registrationsApi, eventsApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { formatDateTime, formatPrice, categoryLabel } from "@/lib/event-utils";
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
}

function Dashboard() {
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
            <h1 className="font-display text-3xl font-bold">Your dashboard</h1>
            <p className="mt-1 text-muted-foreground">
              Manage the events you host and the ones you've joined.
            </p>
          </div>
          <Button asChild variant="hero">
            <Link to="/events/new">
              <CalendarPlus className="h-4 w-4" /> Create event
            </Link>
          </Button>
        </div>

        <Tabs value={tab} onValueChange={setTab} className="mt-8">
          <TabsList className="grid w-full max-w-md grid-cols-2">
            <TabsTrigger value="participating">
              Participating
              {participating.data ? ` (${participating.data.length})` : ""}
            </TabsTrigger>
            <TabsTrigger value="created">
              Created{created.data ? ` (${created.data.length})` : ""}
            </TabsTrigger>
          </TabsList>

          {/* Participating */}
          <TabsContent value="participating" className="mt-6 space-y-4">
            {participating.isLoading && <p className="text-muted-foreground">Loading…</p>}
            {participating.data?.length === 0 && (
              <EmptyState
                icon={Ticket}
                title="No events yet"
                desc="Browse events and register to see them here."
                action={
                  <Button asChild variant="outline">
                    <Link to="/events">Browse events</Link>
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
                            ? "Free"
                            : reg.payment_status === "paid"
                              ? "Paid"
                              : "Payment due"}
                        </Badge>
                      </div>
                      <h3 className="mt-2 text-lg font-semibold">{ev.title}</h3>
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                      </p>
                      {ev.location && (
                        <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                          <MapPin className="h-4 w-4" /> {ev.location}
                        </p>
                      )}
                    </div>
                    {reg.payment_status === "unpaid" ? (
                      <Button asChild size="sm">
                        <Link to="/events/$eventId" params={{ eventId: ev.id }}>
                          Complete payment
                        </Link>
                      </Button>
                    ) : (
                      <Button variant="outline" size="sm" onClick={() => downloadICS(ev)}>
                        <Download className="h-4 w-4" /> Add to calendar
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
          </TabsContent>

          {/* Created */}
          <TabsContent value="created" className="mt-6 space-y-4">
            {created.isLoading && <p className="text-muted-foreground">Loading…</p>}
            {created.data?.length === 0 && (
              <EmptyState
                icon={CalendarPlus}
                title="No events created"
                desc="Host your first race, ride or gathering."
                action={
                  <Button asChild variant="hero">
                    <Link to="/events/new">Create event</Link>
                  </Button>
                }
              />
            )}
            {created.data?.map((ev: any) => {
              const count = ev.registrations?.[0]?.count ?? 0;
              return (
                <div
                  key={ev.id}
                  className="rounded-2xl border border-border bg-card p-5 shadow-[var(--shadow-card)]"
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <div className="flex items-center gap-2">
                        <Badge variant="secondary">{categoryLabel(ev.category)}</Badge>
                        {!ev.is_published && <Badge variant="outline">Draft</Badge>}
                        <Badge variant="outline">{formatPrice(ev.price_cents, ev.currency)}</Badge>
                      </div>
                      <h3 className="mt-2 text-lg font-semibold">{ev.title}</h3>
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                      </p>
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                        <Users className="h-4 w-4" /> {count}
                        {ev.capacity ? ` / ${ev.capacity}` : ""} participants
                      </p>
                    </div>
                    <Button asChild variant="outline" size="sm">
                      <Link to="/dashboard/events/$eventId" params={{ eventId: ev.id }}>
                        <Settings className="h-4 w-4" /> Manage
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
