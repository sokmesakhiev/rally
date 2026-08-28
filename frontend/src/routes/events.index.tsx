import { useEffect, useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery, keepPreviousData } from "@tanstack/react-query";
import {
  CalendarDays,
  MapPin,
  ArrowRight,
  Ticket,
  Users,
  Search,
  X,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { eventsApi } from "@/lib/api-client";
import { SiteHeader } from "@/components/site-header";
import { PresentedByInline } from "@/components/presented-by";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import {
  formatDateTime,
  formatPrice,
  categoryLabel,
  eventCategoryOptions,
} from "@/lib/event-utils";

const PER_PAGE = 12;

const VALUE_PROP_ITEMS = [
  { icon: CalendarDays, key: "realDates" },
  { icon: Users, key: "community" },
  { icon: Ticket, key: "registerFast" },
] as const;

export const Route = createFileRoute("/events/")({
  head: () => ({
    meta: [
      { title: "Browse events — Rally" },
      {
        name: "description",
        content: "Discover running races, group rides and community gatherings to join.",
      },
    ],
  }),
  component: BrowseEvents,
});

function BrowseEvents() {
  const { t } = useTranslation();

  // `searchInput` is what the user is typing; `search` is the debounced value
  // actually sent to the API. Without the split, every keystroke would fire a
  // request.
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState<string | null>(null);
  const [page, setPage] = useState(1);

  useEffect(() => {
    const timer = setTimeout(() => setSearch(searchInput), 300);
    return () => clearTimeout(timer);
  }, [searchInput]);

  // Any change to what's being searched/filtered invalidates the current page
  // number — staying on page 4 of a new, shorter result set would show nothing.
  useEffect(() => {
    setPage(1);
  }, [search, category]);

  const query = useQuery({
    queryKey: ["published-events", search, category, page],
    queryFn: () =>
      eventsApi.list({
        q: search || undefined,
        category: category ?? undefined,
        page,
        perPage: PER_PAGE,
      }),
    // Keeps the previous page's results on screen while the next page loads,
    // instead of flashing an empty grid on every page change.
    placeholderData: keepPreviousData,
  });

  const events = query.data?.events;
  const meta = query.data?.meta;
  const totalPages = meta?.total_pages ?? 0;
  const isFiltering = Boolean(search) || Boolean(category);

  const clearFilters = () => {
    setSearchInput("");
    setSearch("");
    setCategory(null);
  };

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-5xl px-5 py-10">
        {/* Intro — explains what this page is before the listing itself */}
        <section className="border-b border-border pb-10">
          <span className="inline-flex items-center gap-2 rounded-full border border-border bg-card/60 px-3 py-1 text-xs font-medium text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-primary" />
            {t("eventsList.openForRegistration")}
          </span>
          <h1 className="mt-4 font-display text-3xl font-bold md:text-4xl">
            {t("eventsList.titlePrefix")}{" "}
            <span className="text-gradient">{t("eventsList.titleHighlight")}</span>.
          </h1>
          <p className="mt-3 max-w-2xl text-muted-foreground">{t("eventsList.subtitle")}</p>

          <div className="mt-8 grid gap-6 sm:grid-cols-3">
            {VALUE_PROP_ITEMS.map((item) => (
              <div key={item.key} className="flex items-start gap-3">
                <span className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg [background-image:var(--gradient-hero)] text-primary-foreground">
                  <item.icon className="h-4 w-4" />
                </span>
                <div>
                  <p className="text-sm font-semibold">
                    {t(`eventsList.valueProps.${item.key}.title`)}
                  </p>
                  <p className="mt-0.5 text-sm text-muted-foreground">
                    {t(`eventsList.valueProps.${item.key}.desc`)}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </section>

        <div className="mt-10 flex flex-wrap items-center justify-between gap-4">
          <h2 className="font-display text-xl font-semibold">{t("eventsList.upcomingEvents")}</h2>
          {typeof meta?.total_count === "number" && (
            <p className="text-sm text-muted-foreground">
              {t("eventsList.resultCount", { count: meta.total_count })}
            </p>
          )}
        </div>

        {/* Search + category filter. Both are applied server-side, so they
            search the whole catalogue rather than only the current page. */}
        <div className="mt-5 space-y-3">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              type="search"
              value={searchInput}
              onChange={(e) => setSearchInput(e.target.value)}
              placeholder={t("eventsList.searchPlaceholder")}
              aria-label={t("eventsList.searchLabel")}
              className="pl-9"
            />
          </div>

          <div className="flex flex-wrap gap-2">
            <FilterChip
              label={t("eventsList.filterAll")}
              active={category === null}
              onClick={() => setCategory(null)}
            />
            {eventCategoryOptions().map((option) => (
              <FilterChip
                key={option.value}
                label={option.label}
                active={category === option.value}
                onClick={() => setCategory(option.value)}
              />
            ))}
            {isFiltering && (
              <Button variant="ghost" size="sm" onClick={clearFilters} className="gap-1">
                <X className="h-3.5 w-3.5" />
                {t("eventsList.clearFilters")}
              </Button>
            )}
          </div>
        </div>

        {query.isLoading && <p className="mt-8 text-muted-foreground">{t("common.loading")}</p>}
        {query.isError && (
          <p className="mt-8 text-destructive">{(query.error as Error).message}</p>
        )}
        {!query.isLoading && events?.length === 0 && (
          <p className="mt-16 text-center text-muted-foreground">
            {isFiltering ? t("eventsList.emptyFiltered") : t("eventsList.emptyAll")}
          </p>
        )}

        <div className="mt-8 grid gap-5 sm:grid-cols-2">
          {events?.map((ev) => {
            const brandColor = ev.brand_color ?? "#6366f1";
            return (
              <Link
                key={ev.id}
                to="/events/$eventId"
                params={{ eventId: ev.id }}
                className="group overflow-hidden rounded-2xl border border-border bg-card shadow-[var(--shadow-card)] transition-transform hover:-translate-y-1"
              >
                {/* Banner or color strip */}
                {ev.banner_url ? (
                  <div className="relative h-36 w-full overflow-hidden">
                    <img
                      src={ev.banner_url}
                      alt={t("common.bannerAlt", { title: ev.title })}
                      className="h-full w-full object-cover transition-transform group-hover:scale-105"
                    />
                    <div className="absolute inset-0 bg-gradient-to-t from-black/40 to-transparent" />
                  </div>
                ) : (
                  <div className="h-2 w-full" style={{ backgroundColor: brandColor }} />
                )}

                <div className="p-6">
                  {/* Logo + badges row */}
                  <div className="flex items-center gap-3">
                    {ev.logo_url && (
                      <img
                        src={ev.logo_url}
                        alt={t("common.eventLogoAlt")}
                        className="h-8 w-8 rounded-lg border border-border object-cover flex-shrink-0"
                      />
                    )}
                    <div className="flex items-center gap-2">
                      <Badge
                        variant="secondary"
                        style={{
                          backgroundColor: `${brandColor}22`,
                          color: brandColor,
                          borderColor: `${brandColor}44`,
                        }}
                      >
                        {categoryLabel(ev.category)}
                      </Badge>
                      <Badge variant="outline">{formatPrice(ev.price_cents, ev.currency)}</Badge>
                    </div>
                  </div>

                  <h3 className="mt-3 text-lg font-semibold">{ev.title}</h3>
                  {/* Inline (not a link) — this card is already wrapped in
                      one, and nesting anchors is invalid HTML. */}
                  <div className="mt-2">
                    <PresentedByInline organization={ev.organization} />
                  </div>
                  <p className="mt-2 flex items-center gap-1.5 text-sm text-muted-foreground">
                    <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                  </p>
                  {ev.location && (
                    <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                      <MapPin className="h-4 w-4" /> {ev.location}
                    </p>
                  )}
                  <span
                    className="mt-4 inline-flex items-center gap-1 text-sm font-medium transition-transform group-hover:translate-x-1"
                    style={{ color: brandColor }}
                  >
                    {t("eventsList.viewAndRegister")} <ArrowRight className="h-4 w-4" />
                  </span>
                </div>
              </Link>
            );
          })}
        </div>
        {totalPages > 1 && (
          <nav
            className="mt-10 flex items-center justify-center gap-3"
            aria-label={t("eventsList.paginationLabel")}
          >
            <Button
              variant="outline"
              size="sm"
              disabled={page <= 1 || query.isFetching}
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              className="gap-1"
            >
              <ChevronLeft className="h-4 w-4" />
              {t("common.previous")}
            </Button>

            <span className="text-sm text-muted-foreground" aria-live="polite">
              {t("eventsList.pageOf", { page, totalPages })}
            </span>

            <Button
              variant="outline"
              size="sm"
              disabled={page >= totalPages || query.isFetching}
              onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
              className="gap-1"
            >
              {t("common.next")}
              <ChevronRight className="h-4 w-4" />
            </Button>
          </nav>
        )}
      </main>
    </div>
  );
}

function FilterChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`rounded-full border px-3 py-1 text-sm font-medium transition-colors ${
        active
          ? "border-primary bg-primary text-primary-foreground"
          : "border-border bg-card text-muted-foreground hover:text-foreground"
      }`}
    >
      {label}
    </button>
  );
}
