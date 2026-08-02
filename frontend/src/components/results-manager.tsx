import { useRef, useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { Trophy, Upload, Loader2, Check, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import {
  registrationsApi,
  resultsApi,
  type ApiRegistration,
  type ApiResultsImportSummary,
} from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { formatFinishTime, parseFinishTime } from "@/lib/event-utils";

interface ResultsManagerProps {
  eventId: string;
  participants: ApiRegistration[];
  onChanged: () => void;
}

/** Organizer-facing finish-time entry: a CSV bulk-import card (email,
 * finish_time columns) plus a per-participant manual editor below it, so
 * a small race can skip the CSV step entirely. Optional by design — most
 * event types (a social gathering, an untimed ride) never get a result. */
export function ResultsManager({ eventId, participants, onChanged }: ResultsManagerProps) {
  const { t } = useTranslation();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [summary, setSummary] = useState<ApiResultsImportSummary | null>(null);

  const setResult = useMutation({
    mutationFn: ({ id, seconds }: { id: string; seconds: number | null }) =>
      registrationsApi.setResult(id, seconds),
    onSuccess: (_data, vars) => {
      setDrafts((d) => {
        const next = { ...d };
        delete next[vars.id];
        return next;
      });
      onChanged();
      toast.success(t("results.savedToast"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const importCsv = useMutation({
    mutationFn: (file: File) => resultsApi.importCsv(eventId, file),
    onSuccess: (data) => {
      setSummary(data);
      onChanged();
      if (data.errors.length === 0) {
        toast.success(t("results.importSuccessToast", { count: data.updated }));
      } else {
        toast.warning(
          t("results.importPartialToast", { count: data.updated, errors: data.errors.length }),
        );
      }
    },
    onError: (e: any) => toast.error(e.message),
    onSettled: () => {
      if (fileInputRef.current) fileInputRef.current.value = "";
    },
  });

  const draftFor = (p: ApiRegistration) =>
    drafts[p.id] ?? (p.finish_time_seconds != null ? formatFinishTime(p.finish_time_seconds) : "");

  const handleSave = (p: ApiRegistration) => {
    const raw = draftFor(p).trim();
    if (!raw) {
      setResult.mutate({ id: p.id, seconds: null });
      return;
    }
    const seconds = parseFinishTime(raw);
    if (seconds == null) {
      toast.error(t("results.invalidTime"));
      return;
    }
    setResult.mutate({ id: p.id, seconds });
  };

  return (
    <div className="space-y-6">
      {/* CSV import */}
      <div className="rounded-2xl border border-border bg-card p-6">
        <div className="mb-1 flex items-center gap-2">
          <Upload className="h-5 w-5 text-muted-foreground" />
          <h2 className="font-semibold">{t("results.importTitle")}</h2>
        </div>
        <p className="mb-1 text-sm text-muted-foreground">{t("results.importDesc")}</p>
        <p className="mb-4 font-mono text-xs text-muted-foreground">email,finish_time</p>

        <input
          ref={fileInputRef}
          type="file"
          accept=".csv,text/csv"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) importCsv.mutate(file);
          }}
        />
        <Button
          variant="outline"
          size="sm"
          disabled={importCsv.isPending}
          onClick={() => fileInputRef.current?.click()}
        >
          {importCsv.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {t("results.chooseCsv")}
        </Button>

        {summary && (
          <div className="mt-4 rounded-xl border border-border bg-muted/40 p-4 text-sm">
            <p className="font-medium">
              {t("results.importSummaryUpdated", { count: summary.updated })}
            </p>
            {summary.errors.length > 0 && (
              <ul className="mt-2 space-y-1 text-xs text-destructive">
                {summary.errors.map((err, i) => (
                  <li key={i}>
                    {t("results.importSummaryErrorRow", {
                      row: err.row,
                      email: err.email,
                      reason: err.reason,
                    })}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>

      {/* Manual entry */}
      <div className="overflow-hidden rounded-2xl border border-border">
        <div className="flex items-center gap-2 border-b border-border bg-muted/40 px-5 py-3">
          <Trophy className="h-4 w-4 text-muted-foreground" />
          <p className="text-sm font-semibold">{t("results.manualTitle")}</p>
        </div>
        {participants.length === 0 ? (
          <p className="p-8 text-center text-sm text-muted-foreground">
            {t("manageEvent.noParticipants")}
          </p>
        ) : (
          <div className="divide-y divide-border">
            {participants.map((p) => (
              <div key={p.id} className="flex flex-wrap items-center justify-between gap-3 p-4">
                <p className="min-w-0 truncate font-medium">
                  {p.profile?.display_name ?? t("manageEvent.participantFallback")}
                </p>
                <div className="flex items-center gap-2">
                  <Input
                    value={draftFor(p)}
                    onChange={(e) => setDrafts((d) => ({ ...d, [p.id]: e.target.value }))}
                    placeholder={t("results.timePlaceholder")}
                    className="h-8 w-28 text-sm"
                  />
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={setResult.isPending}
                    onClick={() => handleSave(p)}
                  >
                    <Check className="h-4 w-4" />
                  </Button>
                  {p.finish_time_seconds != null && (
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={setResult.isPending}
                      onClick={() => setResult.mutate({ id: p.id, seconds: null })}
                    >
                      <X className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
