import { ChevronLeft, ChevronRight } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { ApiPageMeta } from "@/lib/api-client";
import { Button } from "@/components/ui/button";

interface ListPagerProps {
  meta: ApiPageMeta | undefined;
  onPageChange: (page: number) => void;
  /** True while the next page is in flight — disables both buttons so a fast
   *  double-click can't skip a page. */
  busy?: boolean;
  /** Draws the rule above the controls. On by default, because the usual
   *  position is appended to a list of rows inside a bordered card, where the
   *  rule is what separates the pager from the last row. Pass false when the
   *  pager is the only child of its own bordered box — the box's top border
   *  and this one would otherwise stack into a 2px line. */
  bordered?: boolean;
}

/**
 * Numbered page controls for the organizer's participant lists.
 *
 * Shows "x–y of N", not just a page number, because N is the figure an
 * organizer actually wants (how many people are coming) and a bare "Page 2 of
 * 7" makes them do arithmetic to get it.
 *
 * Renders nothing when there's one page or none — a pager under a list of four
 * people is noise.
 */
export function ListPager({ meta, onPageChange, busy = false, bordered = true }: ListPagerProps) {
  const { t } = useTranslation();

  if (!meta || meta.total_pages <= 1) return null;

  const first = (meta.page - 1) * meta.per_page + 1;
  // Not page * per_page — the last page is usually short, and claiming
  // "51–75 of 62" is the kind of small wrongness that erodes trust in the
  // numbers above it.
  const last = Math.min(meta.page * meta.per_page, meta.total_count);

  return (
    <div
      className={`flex flex-wrap items-center justify-between gap-3 px-5 py-3 ${
        bordered ? "border-t border-border" : ""
      }`}
    >
      <p className="text-sm text-muted-foreground">
        {t("pagination.showing", { first, last, total: meta.total_count })}
      </p>
      <div className="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={busy || meta.page <= 1}
          onClick={() => onPageChange(meta.page - 1)}
        >
          <ChevronLeft className="h-4 w-4" /> {t("pagination.previous")}
        </Button>
        <span className="text-sm text-muted-foreground">
          {t("pagination.pageOf", { page: meta.page, pages: meta.total_pages })}
        </span>
        <Button
          variant="outline"
          size="sm"
          disabled={busy || meta.page >= meta.total_pages}
          onClick={() => onPageChange(meta.page + 1)}
        >
          {t("pagination.next")} <ChevronRight className="h-4 w-4" />
        </Button>
      </div>
    </div>
  );
}
