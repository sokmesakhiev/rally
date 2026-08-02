import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { CalendarDays, Users, Ticket, Wallet, Trophy } from "lucide-react";
import { useTranslation } from "react-i18next";
import { adminApi, type ApiReportPeriod } from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { categoryLabel, formatDate } from "@/lib/event-utils";
import i18n from "@/lib/i18n";

const PERIODS: ApiReportPeriod[] = ["week", "month", "year"];

// Deliberately doesn't fall back to a "Free" label the way event-utils'
// formatPrice does — on a revenue report, $0.00 is a meaningful (if
// unexciting) data point, not the "this event costs nothing" case that
// formatPrice is optimized for.
function formatMoney(cents: number, currency: string): string {
  return new Intl.NumberFormat(i18n.language, {
    style: "currency",
    currency: currency.toUpperCase(),
  }).format(cents / 100);
}

// events_by_period / platform_revenue_by_period labels are one of
// "YYYY" (year), "YYYY-MM" (month), or "YYYY-MM-DD" (start of week) —
// reformatted here for a friendlier chart axis without changing what the
// API returns (which stays sortable/parseable as-is).
function formatPeriodLabel(period: string): string {
  if (/^\d{4}$/.test(period)) return period;
  if (/^\d{4}-\d{2}$/.test(period)) {
    return new Date(`${period}-01T00:00:00`).toLocaleDateString(i18n.language, {
      month: "short",
      year: "numeric",
    });
  }
  if (/^\d{4}-\d{2}-\d{2}$/.test(period)) {
    return new Date(`${period}T00:00:00`).toLocaleDateString(i18n.language, {
      month: "short",
      day: "numeric",
    });
  }
  return period;
}

/** The admin dashboard's landing tab: platform-wide KPIs, an events-created
 * trend (with a week/month/year toggle), Rally's own revenue from event
 * plan payments, and the most-registered events. Read-only — all the
 * state-changing moderation actions live in the Users/Events tabs. */
export function AdminOverview() {
  const { t } = useTranslation();
  const [period, setPeriod] = useState<ApiReportPeriod>("month");

  const query = useQuery({
    queryKey: ["admin-reports", period],
    queryFn: () => adminApi.reports(period),
  });

  if (query.isLoading) {
    return <p className="text-muted-foreground">{t("common.loading")}</p>;
  }
  if (query.isError) {
    return <p className="text-destructive">{(query.error as Error).message}</p>;
  }
  if (!query.data) return null;

  const { totals, events_by_period, platform_revenue_by_period, top_events } = query.data;

  const eventsChartData = events_by_period.map((b) => ({
    label: formatPeriodLabel(b.period),
    count: b.count,
  }));
  const revenueChartData = platform_revenue_by_period.map((b) => ({
    label: formatPeriodLabel(b.period),
    amount: b.amount_cents / 100,
  }));

  return (
    <div className="space-y-6">
      {/* KPI cards */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          icon={CalendarDays}
          label={t("admin.overview.kpiEvents")}
          value={`${totals.events_count}`}
          sub={t("admin.overview.kpiEventsPublished", { count: totals.published_events_count })}
        />
        <KpiCard
          icon={Users}
          label={t("admin.overview.kpiUsers")}
          value={`${totals.users_count}`}
        />
        <KpiCard
          icon={Ticket}
          label={t("admin.overview.kpiParticipants")}
          value={`${totals.registrations_count}`}
        />
        <KpiCard
          icon={Wallet}
          label={t("admin.overview.kpiPlatformRevenue")}
          value={formatMoney(totals.platform_revenue_cents, "usd")}
          sub={t("admin.overview.kpiPlatformRevenueSub")}
        />
      </div>

      {totals.registration_volume.length > 0 && (
        <div className="rounded-2xl border border-border bg-card p-5">
          <p className="text-sm font-semibold">{t("admin.overview.registrationVolumeTitle")}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {t("admin.overview.registrationVolumeDesc")}
          </p>
          <div className="mt-3 flex flex-wrap gap-6">
            {totals.registration_volume.map((rv) => (
              <div key={rv.currency}>
                <p className="text-lg font-bold">{formatMoney(rv.amount_cents, rv.currency)}</p>
                <p className="text-xs uppercase text-muted-foreground">{rv.currency}</p>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Period toggle */}
      <div className="flex items-center justify-end gap-2">
        {PERIODS.map((p) => (
          <Button
            key={p}
            size="sm"
            variant={period === p ? "default" : "outline"}
            onClick={() => setPeriod(p)}
          >
            {t(`admin.overview.period.${p}`)}
          </Button>
        ))}
      </div>

      {/* Events created chart */}
      <div className="rounded-2xl border border-border bg-card p-5">
        <p className="mb-4 text-sm font-semibold">{t("admin.overview.eventsChartTitle")}</p>
        <ResponsiveContainer width="100%" height={240}>
          <BarChart data={eventsChartData}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} />
            <XAxis dataKey="label" tick={{ fontSize: 12 }} />
            <YAxis allowDecimals={false} tick={{ fontSize: 12 }} width={32} />
            <Tooltip formatter={(value) => [String(value), t("admin.overview.eventsChartTitle")]} />
            <Bar dataKey="count" fill="#6366f1" radius={[4, 4, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Platform revenue chart */}
      <div className="rounded-2xl border border-border bg-card p-5">
        <p className="mb-4 text-sm font-semibold">{t("admin.overview.revenueChartTitle")}</p>
        <ResponsiveContainer width="100%" height={240}>
          <BarChart data={revenueChartData}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} />
            <XAxis dataKey="label" tick={{ fontSize: 12 }} />
            <YAxis allowDecimals={false} tick={{ fontSize: 12 }} width={48} />
            <Tooltip
              formatter={(value) => [formatMoney(Math.round(Number(value) * 100), "usd"), ""]}
            />
            <Bar dataKey="amount" fill="#22c55e" radius={[4, 4, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Top events by participants */}
      <div className="overflow-hidden rounded-2xl border border-border">
        <div className="flex items-center gap-2 border-b border-border bg-muted/40 px-5 py-3">
          <Trophy className="h-4 w-4 text-muted-foreground" />
          <p className="text-sm font-semibold">{t("admin.overview.topEventsTitle")}</p>
        </div>
        {top_events.length === 0 ? (
          <p className="p-8 text-center text-sm text-muted-foreground">
            {t("admin.overview.noEvents")}
          </p>
        ) : (
          <div className="divide-y divide-border">
            {top_events.map((ev, i) => (
              <div key={ev.id} className="flex items-center justify-between gap-3 p-4">
                <div className="flex min-w-0 items-center gap-3">
                  <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-muted text-xs font-semibold text-muted-foreground">
                    {i + 1}
                  </span>
                  <div className="min-w-0">
                    <p className="truncate font-medium">{ev.title}</p>
                    <p className="text-xs text-muted-foreground">
                      {categoryLabel(ev.category)} · {formatDate(ev.start_at)}
                    </p>
                  </div>
                </div>
                <span className="shrink-0 text-sm font-semibold">{ev.registrations_count}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function KpiCard({
  icon: Icon,
  label,
  value,
  sub,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <div className="rounded-2xl border border-border bg-card p-5">
      <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-muted text-secondary">
        <Icon className="h-5 w-5" />
      </span>
      <p className="mt-3 text-2xl font-bold">{value}</p>
      <p className="text-sm text-muted-foreground">{label}</p>
      {sub && <p className="mt-0.5 text-xs text-muted-foreground">{sub}</p>}
    </div>
  );
}
