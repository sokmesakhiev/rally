import { useRef, useState } from "react";
import { FileText, Upload, X, Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { uploadsApi } from "@/lib/api-client";
import { Button } from "@/components/ui/button";

interface CertificateTemplateUploadProps {
  value: string | null;
  onChange: (url: string | null) => void;
}

/**
 * Organizer-facing upload for the .odt certificate-of-participation
 * template (see Certificates::MergeOdt / Certificates::RenderPdf on the
 * backend). Deliberately not built on ImageUpload — there's no useful
 * thumbnail preview for an ODT, just a filename and the placeholder-token
 * reference organizers need to actually author the template.
 */
export function CertificateTemplateUpload({ value, onChange }: CertificateTemplateUploadProps) {
  const { t } = useTranslation();
  const inputRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleFile(file: File) {
    setError(null);
    setUploading(true);
    try {
      const url = await uploadsApi.upload(file, "certificate_template");
      onChange(url);
    } catch (e: any) {
      setError(e.message ?? t("certificateTemplate.uploadFailed"));
    } finally {
      setUploading(false);
    }
  }

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (file) handleFile(file);
  }

  return (
    <div className="space-y-3">
      {value ? (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-muted/40 p-3">
          <div className="flex min-w-0 items-center gap-2">
            <FileText className="h-5 w-5 shrink-0 text-muted-foreground" />
            <span className="truncate text-sm font-medium">
              {t("certificateTemplate.templateUploaded")}
            </span>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => inputRef.current?.click()}
              disabled={uploading}
            >
              {uploading ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                t("certificateTemplate.replace")
              )}
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => onChange(null)}
              disabled={uploading}
            >
              <X className="h-4 w-4" />
            </Button>
          </div>
        </div>
      ) : (
        <div
          className="flex cursor-pointer flex-col items-center justify-center gap-1.5 rounded-xl border-2 border-dashed border-border bg-muted/40 p-6 text-center text-muted-foreground transition-colors hover:border-primary/50"
          onClick={() => inputRef.current?.click()}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === "Enter" && inputRef.current?.click()}
        >
          {uploading ? (
            <Loader2 className="h-5 w-5 animate-spin" />
          ) : (
            <>
              <Upload className="h-5 w-5" />
              <p className="text-xs">{t("certificateTemplate.clickToUpload")}</p>
            </>
          )}
        </div>
      )}

      {error && <p className="text-xs text-destructive">{error}</p>}

      <input
        ref={inputRef}
        type="file"
        accept=".odt,application/vnd.oasis.opendocument.text"
        className="hidden"
        onChange={handleChange}
      />

      <div className="rounded-xl border border-border bg-muted/20 p-3 text-xs text-muted-foreground space-y-1.5">
        <p className="font-medium text-foreground">{t("certificateTemplate.tokensTitle")}</p>
        <p>
          <code className="rounded bg-muted px-1 py-0.5">{"{{participant_name}}"}</code>{" "}
          <code className="rounded bg-muted px-1 py-0.5">{"{{event_title}}"}</code>{" "}
          <code className="rounded bg-muted px-1 py-0.5">{"{{event_date}}"}</code>{" "}
          <code className="rounded bg-muted px-1 py-0.5">{"{{event_location}}"}</code>
        </p>
        <p>{t("certificateTemplate.tokensHint")}</p>
      </div>
    </div>
  );
}
