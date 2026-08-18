import { Trophy, Medal } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { ApiLeaderboardGroup } from "@/lib/api-client";
import { Badge } from "@/components/ui/badge";
import { formatFinishTime } from "@/lib/event-utils";
import { cn } from "@/lib/utils";

interface ResultsLeaderboardProps {
  groups: ApiLeaderboardGroup[];
  /** Highlights this participant's own row, when logged in. */
  currentUserId?: string;
  brandColor: string;
}

const MEDAL_COLORS: Record<number, string> = {
  1: "#eab308",
  2: "#94a3b8",
  3: "#b45309",
};

/** Public-facing results section — one ranked table per event type (or a
 * single combined one), shown on the event detail page. The parent decides
 * whether to render this at all (only when at least one group has entries —
 * see events.$eventId.tsx), so this component doesn't need an "empty"
 * state of its own. */
export function ResultsLeaderboard({ groups, currentUserId, brandColor }: ResultsLeaderboardProps) {
  const { t } = useTranslation();
  const visibleGroups = groups.filter((g) => g.results.length > 0);
  if (visibleGroups.length === 0) return null;

  return (
    <div className="mt-8 rounded-2xl border border-border bg-card p-6">
      <div className="mb-1 flex items-center gap-2">
        <Trophy className="h-5 w-5 text-muted-foreground" />
        <h2 className="font-semibold">{t("results.leaderboardTitle")}</h2>
      </div>
      <p className="mb-5 text-sm text-muted-foreground">{t("results.leaderboardDesc")}</p>

      <div className="space-y-6">
        {visibleGroups.map((group) => (
          <div key={group.event_type_id ?? "overall"}>
            {group.event_type_name && (
              <p className="mb-2 text-sm font-semibold" style={{ color: brandColor }}>
                {group.event_type_name}
              </p>
            )}
            <div className="overflow-hidden rounded-xl border border-border">
              <div className="divide-y divide-border">
                {group.results.map((entry) => (
                  <div
                    key={entry.registration_id}
                    className={cn(
                      "flex items-center justify-between gap-3 px-4 py-2.5",
                      entry.user_id === currentUserId && "bg-primary/5",
                    )}
                  >
                    <div className="flex min-w-0 items-center gap-3">
                      {entry.placement <= 3 ? (
                        <Medal
                          className="h-5 w-5 shrink-0"
                          style={{ color: MEDAL_COLORS[entry.placement] }}
                        />
                      ) : (
                        <span className="w-5 shrink-0 text-center text-sm font-medium text-muted-foreground">
                          {entry.placement}
                        </span>
                      )}
                      <p className="truncate text-sm font-medium">
                        {entry.display_name ?? t("results.anonymousParticipant")}
                      </p>
                      {entry.user_id === currentUserId && (
                        <Badge variant="secondary" className="shrink-0 text-xs">
                          {t("results.youBadge")}
                        </Badge>
                      )}
                    </div>
                    <span className="shrink-0 font-mono text-sm text-muted-foreground">
                      {formatFinishTime(entry.finish_time_seconds)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
