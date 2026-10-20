import { useState } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { Hash, Loader2, AlertTriangle } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";

import { registrationsApi, type ApiBibAssignmentGroup } from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

/**
 * Assigns bib numbers to everyone who doesn't have one.
 *
 * **The preview is the feature.** Bibs get printed, and a number is on a
 * person's chest all day — so the dialog shows exactly which numbers would be
 * issued, per distance, before anything is written. The server computes it
 * with the same code path that performs the assignment (a GET rather than a
 * flag on the POST), so the preview cannot drift from the result.
 *
 * Running it twice is safe and expected: existing numbers are never touched,
 * so an organizer assigns when entries close and again after the late
 * additions. The button says "Assign" rather than "Generate" for that reason —
 * nothing here regenerates anything.
 */
export function BibAssignmentDialog({
  eventId,
  disabled,
  onAssigned,
}: {
  eventId: string;
  disabled?: boolean;
  onAssigned: () => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  const preview = useQuery({
    queryKey: ["bib-assignment-preview", eventId],
    queryFn: () => registrationsApi.bibAssignmentPreview(eventId),
    // Only when the dialog is open. The preview walks every unnumbered
    // registration on the event; it is not something to run on page load.
    enabled: open,
    // A stale preview is worse than a slow one — somebody may have registered
    // since the dialog last opened.
    staleTime: 0,
  });

  const assign = useMutation({
    mutationFn: () => registrationsApi.assignBibNumbers(eventId),
    onSuccess: (result) => {
      setOpen(false);
      onAssigned();
      toast.success(t("bibAssignment.toastAssigned", { count: result.assigned_count }));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const groups = preview.data?.groups ?? [];
  const total = preview.data?.assigned_count ?? 0;
  const unconfigured = groups.filter((g) => !g.configured && g.pending_count > 0);

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <Button variant="outline" size="sm" disabled={disabled} onClick={() => setOpen(true)}>
        <Hash className="h-4 w-4" />
        {t("bibAssignment.assign")}
      </Button>

      <AlertDialogContent className="max-w-lg">
        <AlertDialogHeader>
          <AlertDialogTitle>{t("bibAssignment.title")}</AlertDialogTitle>
          <AlertDialogDescription>{t("bibAssignment.description")}</AlertDialogDescription>
        </AlertDialogHeader>

        {preview.isLoading && (
          <p className="py-6 text-center text-sm text-muted-foreground">{t("common.loading")}</p>
        )}
        {preview.isError && (
          <p className="py-6 text-center text-sm text-destructive">
            {(preview.error as Error).message}
          </p>
        )}

        {preview.data && (
          <div className="space-y-3">
            {groups.length === 0 && (
              <p className="text-sm text-muted-foreground">{t("bibAssignment.nobodyWaiting")}</p>
            )}

            {groups.map((group) => (
              <GroupRow key={group.key ?? "untyped"} group={group} />
            ))}

            {unconfigured.length > 0 && (
              // The one reason assignment legitimately does nothing. Saying so
              // here, with the fix, beats a success toast over an empty result.
              <p className="rounded-md bg-muted p-3 text-xs text-muted-foreground">
                {t("bibAssignment.unconfiguredHint")}
              </p>
            )}
          </div>
        )}

        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={(e) => {
              // The mutation owns closing, so a server refusal leaves the
              // preview on screen rather than dropping the organizer back to
              // the list with nothing to read.
              e.preventDefault();
              assign.mutate();
            }}
            disabled={assign.isPending || preview.isLoading || total === 0}
            className="gap-2"
          >
            {assign.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("bibAssignment.confirm", { count: total })}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function GroupRow({ group }: { group: ApiBibAssignmentGroup }) {
  const { t } = useTranslation();

  return (
    <div className="rounded-lg border border-border p-3">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-sm font-medium">{group.label}</span>
        {group.configured ? (
          <span className="text-sm text-muted-foreground">
            {group.first_number && group.last_number
              ? t("bibAssignment.range", {
                  first: group.first_number,
                  last: group.last_number,
                  count: group.pending_count,
                })
              : t("bibAssignment.nothingToDo")}
          </span>
        ) : (
          <span className="text-sm text-amber-600">
            {t("bibAssignment.notConfigured", { count: group.skipped_count })}
          </span>
        )}
      </div>

      {group.warning && (
        // Advisory, never an error — two runners can't share a number either
        // way. But a range running into the next one is the sort of thing
        // discovered at the printer otherwise.
        <p className="mt-2 flex items-start gap-1.5 text-xs text-amber-600">
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          {group.warning}
        </p>
      )}
    </div>
  );
}
