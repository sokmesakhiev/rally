import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  Activity,
  Bike,
  Users,
  CalendarCheck,
  MapPin,
  Trophy,
  Ticket,
  BarChart3,
  Bell,
  ArrowRight,
  Check,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { SiteHeader } from "@/components/site-header";
import { eventPlansApi } from "@/lib/api-client";
import { formatPrice } from "@/lib/event-utils";
import heroImg from "@/assets/hero-runners.jpg";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Rally — Create & Join Running Events" },
      {
        name: "description",
        content:
          "Rally lets anyone organize running races, group rides, and community gatherings in minutes. Manage registrations, send updates, and grow your community.",
      },
      { property: "og:title", content: "Rally — Create & Join Running Events" },
      { property: "og:type", content: "website" },
      {
        property: "og:description",
        content: "Organize running races, group rides, and community gatherings in minutes.",
      },
      { property: "og:image", content: heroImg },
      { name: "twitter:image", content: heroImg },
    ],
  }),
  component: Index,
});

const FEATURE_ITEMS = [
  { icon: CalendarCheck, key: "setup" },
  { icon: Ticket, key: "registrations" },
  { icon: MapPin, key: "routes" },
  { icon: Bell, key: "updates" },
  { icon: BarChart3, key: "dashboard" },
  { icon: Trophy, key: "results" },
] as const;

const EVENT_TYPE_ITEMS = [
  { icon: Activity, key: "running" },
  { icon: Bike, key: "rides" },
  { icon: Users, key: "gatherings" },
] as const;

const STEP_ITEMS = ["create", "share", "run"] as const;

function Index() {
  const { t } = useTranslation();

  const plansQuery = useQuery({
    queryKey: ["event-plans"],
    queryFn: async () => {
      const { plans } = await eventPlansApi.list();
      return plans;
    },
  });

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />

      {/* Hero */}
      <section className="relative overflow-hidden">
        <div className="absolute inset-0">
          <img
            src={heroImg}
            alt={t("home.hero.imageAlt")}
            width={1600}
            height={1200}
            className="h-full w-full object-cover"
          />
          <div className="absolute inset-0 bg-gradient-to-r from-background via-background/90 to-background/40" />
          <div className="absolute inset-0 bg-gradient-to-t from-background to-transparent" />
        </div>

        <div className="relative mx-auto max-w-6xl px-5 py-24 md:py-36">
          <div className="max-w-2xl">
            <span className="inline-flex items-center gap-2 rounded-full border border-border bg-card/60 px-3 py-1 text-xs font-medium text-muted-foreground backdrop-blur">
              <span className="h-1.5 w-1.5 rounded-full bg-primary" />
              {t("home.hero.eyebrow")}
            </span>
            <h1 className="mt-6 font-display text-5xl font-extrabold leading-[1.05] md:text-7xl">
              {t("home.hero.titlePrefix")}{" "}
              <span className="text-gradient">{t("home.hero.titleHighlight")}</span>
              {t("home.hero.titleSuffix")}
            </h1>
            <p className="mt-6 max-w-xl text-lg text-muted-foreground">{t("home.hero.subtitle")}</p>
            <div className="mt-9 flex flex-wrap items-center gap-4">
              <Button asChild variant="hero" size="xl">
                <Link to="/auth">
                  {t("home.hero.ctaPrimary")} <ArrowRight className="h-4 w-4" />
                </Link>
              </Button>
              <Button asChild variant="outline" size="xl">
                <a href="#how">{t("home.hero.ctaSecondary")}</a>
              </Button>
            </div>
            <div className="mt-10 flex flex-wrap gap-8 text-sm text-muted-foreground">
              <div>
                <p className="font-display text-2xl font-bold text-foreground">12k+</p>
                <p>{t("home.hero.statEvents")}</p>
              </div>
              <div>
                <p className="font-display text-2xl font-bold text-foreground">480k</p>
                <p>{t("home.hero.statParticipants")}</p>
              </div>
              <div>
                <p className="font-display text-2xl font-bold text-foreground">4.9★</p>
                <p>{t("home.hero.statRating")}</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Event types */}
      <section id="events" className="mx-auto max-w-6xl px-5 py-20">
        <div className="text-center">
          <h2 className="font-display text-3xl font-bold md:text-4xl">
            {t("home.eventTypes.title")}
          </h2>
          <p className="mx-auto mt-3 max-w-xl text-muted-foreground">
            {t("home.eventTypes.subtitle")}
          </p>
        </div>
        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {EVENT_TYPE_ITEMS.map((item) => (
            <div
              key={item.key}
              className="group rounded-2xl border border-border bg-card p-8 shadow-[var(--shadow-card)] transition-transform hover:-translate-y-1"
            >
              <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-muted text-secondary">
                <item.icon className="h-6 w-6" />
              </span>
              <h3 className="mt-5 text-xl font-semibold">
                {t(`home.eventTypes.items.${item.key}.label`)}
              </h3>
              <p className="mt-2 text-sm text-muted-foreground">
                {t(`home.eventTypes.items.${item.key}.note`)}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* Features */}
      <section id="features" className="border-y border-border bg-card/30">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <div className="max-w-2xl">
            <h2 className="font-display text-3xl font-bold md:text-4xl">
              {t("home.features.title")}
            </h2>
            <p className="mt-3 text-muted-foreground">{t("home.features.subtitle")}</p>
          </div>
          <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {FEATURE_ITEMS.map((item) => (
              <div key={item.key} className="rounded-2xl border border-border bg-background p-6">
                <span className="flex h-11 w-11 items-center justify-center rounded-lg [background-image:var(--gradient-hero)] text-primary-foreground">
                  <item.icon className="h-5 w-5" />
                </span>
                <h3 className="mt-4 text-lg font-semibold">
                  {t(`home.features.items.${item.key}.title`)}
                </h3>
                <p className="mt-2 text-sm text-muted-foreground">
                  {t(`home.features.items.${item.key}.desc`)}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Pricing */}
      <section id="pricing" className="mx-auto max-w-6xl px-5 py-20">
        <div className="text-center">
          <h2 className="font-display text-3xl font-bold md:text-4xl">{t("home.pricing.title")}</h2>
          <p className="mx-auto mt-3 max-w-xl text-muted-foreground">
            {t("home.pricing.subtitle")}
          </p>
        </div>

        {plansQuery.isLoading && (
          <p className="mt-12 text-center text-sm text-muted-foreground">
            {t("home.pricing.loading")}
          </p>
        )}

        <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-5">
          {plansQuery.data?.map((plan) => {
            const isFree = plan.price_cents === 0;
            return (
              <div
                key={plan.id}
                className={`flex flex-col rounded-2xl border p-6 shadow-[var(--shadow-card)] ${
                  isFree ? "border-primary/40 bg-primary/5" : "border-border bg-card"
                }`}
              >
                {isFree && (
                  <span className="mb-3 inline-flex w-fit items-center rounded-full bg-primary/15 px-2.5 py-1 text-xs font-medium text-primary">
                    {t("home.pricing.startHere")}
                  </span>
                )}
                <h3 className="text-lg font-semibold">{plan.label}</h3>
                <p className="mt-2 font-display text-3xl font-bold">
                  {isFree ? t("common.free") : formatPrice(plan.price_cents, "usd")}
                </p>
                <p className="mt-1 text-sm text-muted-foreground">{t("home.pricing.perEvent")}</p>
                <div className="mt-5 flex items-start gap-2 text-sm">
                  <Check className="mt-0.5 h-4 w-4 flex-shrink-0 text-primary" />
                  <span>
                    {t("home.pricing.registrantsUpTo", {
                      count: plan.capacity,
                      formatted: plan.capacity.toLocaleString(),
                    })}
                  </span>
                </div>
                <div className="mt-2 flex items-start gap-2 text-sm">
                  <Check className="mt-0.5 h-4 w-4 flex-shrink-0 text-primary" />
                  <span>{t("home.pricing.dashboardFeature")}</span>
                </div>
                <Button asChild variant={isFree ? "hero" : "outline"} size="sm" className="mt-6">
                  <Link to="/auth">{t("home.pricing.getStarted")}</Link>
                </Button>
              </div>
            );
          })}
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="mx-auto max-w-6xl px-5 py-20">
        <div className="text-center">
          <h2 className="font-display text-3xl font-bold md:text-4xl">{t("home.how.title")}</h2>
          <p className="mx-auto mt-3 max-w-xl text-muted-foreground">{t("home.how.subtitle")}</p>
        </div>
        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {STEP_ITEMS.map((key, i) => (
            <div key={key} className="relative rounded-2xl border border-border bg-card p-8">
              <span className="font-display text-4xl font-bold text-gradient">
                {String(i + 1).padStart(2, "0")}
              </span>
              <h3 className="mt-4 text-xl font-semibold">{t(`home.how.steps.${key}.title`)}</h3>
              <p className="mt-2 text-sm text-muted-foreground">
                {t(`home.how.steps.${key}.desc`)}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* CTA */}
      <section className="mx-auto max-w-6xl px-5 pb-24">
        <div className="overflow-hidden rounded-3xl border border-border p-10 text-center shadow-[var(--shadow-glow)] [background-image:var(--gradient-hero)] md:p-16">
          <h2 className="font-display text-3xl font-bold text-primary-foreground md:text-5xl">
            {t("home.cta.title")}
          </h2>
          <p className="mx-auto mt-4 max-w-xl text-primary-foreground/80">
            {t("home.cta.subtitle")}
          </p>
          <div className="mt-8">
            <Button
              asChild
              size="xl"
              className="bg-background text-foreground hover:bg-background/90"
            >
              <Link to="/auth">
                {t("home.cta.button")} <ArrowRight className="h-4 w-4" />
              </Link>
            </Button>
          </div>
        </div>
      </section>

      <footer className="border-t border-border">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-5 py-8 text-sm text-muted-foreground sm:flex-row">
          <div className="flex items-center gap-2">
            <Activity className="h-4 w-4 text-primary" />
            <span className="font-display font-semibold text-foreground">Rally</span>
          </div>
          <p>{t("home.footer.tagline", { year: new Date().getFullYear() })}</p>
        </div>
      </footer>
    </div>
  );
}
