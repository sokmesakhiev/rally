import { useEffect, useRef, useState } from "react";
import { FileText, Upload, X, Loader2, AlertTriangle, CheckCircle2, Eye } from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  uploadsApi,
  certificatePreviewApi,
  type CertificateTemplateCheck,
  type CertificatePreview,
} from "@/lib/api-client";
import { Button } from "@/components/ui/button";

interface CertificateTemplateUploadProps {
  value: string | null;
  onChange: (url: string | null) => void;
  /** Needed to render a preview against this event's real title/date/location. */
  eventId: string;
}

/** How often to ask whether the render has finished, and when to give up. */
const POLL_MS = 1500;
const POLL_TIMEOUT_MS = 90_000;

/**
 * Organizer-facing upload for the .odt certificate-of-participation template
 * (see Certificates::MergeOdt / Certificates::RenderPdf on the backend).
 *
 * Two separate kinds of feedback, deliberately, because they answer different
 * questions and cost wildly different amounts:
 *
 *   - **The token check** comes back with the upload itself, in milliseconds,
 *     from Certificates::InspectTemplate. It answers "will the placeholders
 *     actually be filled in?" — the failure MergeOdt warns about, where a
 *     token split across formatting silently prints literal braces on every
 *     certificate. No LibreOffice involved.
 *   - **The rendered preview** answers "what will it look like?" and needs a
 *     real LibreOffice conversion, so it runs as a job and is polled. It is
 *     the only thing that catches layout problems — a long event title
 *     wrapping and pushing content onto a second page, say.
 *
 * The check is always shown; the preview is opt-in behind a button, because
 * it is by far the most expensive thing an organizer can ask this app to do.
 */
export function CertificateTemplateUpload({
  value,
  onChange,
  eventId,
}: CertificateTemplateUploadProps) {
  const { t } = useTranslation();
  const inputRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [check, setCheck] = useState<CertificateTemplateCheck | null>(null);
  const [signedId, setSignedId] = useState<string | null>(null);

  const [preview, setPreview] = useState<CertificatePreview | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);

  // Guards every async continuation below. Without it, a poll started for one
  // template can resolve after the organizer has already replaced it and
  // overwrite the newer result with the older one — the same generation guard
  // useSupportChat uses for reconnects.
  const generationRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      generationRef.current += 1;
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  function resetTemplateState() {
    generationRef.current += 1;
    if (timerRef.current) clearTimeout(timerRef.current);
    setPreview(null);
    setPreviewError(null);
    setPreviewing(false);
  }

  async function handleFile(file: File) {
    setError(null);
    setUploading(true);
    resetTemplateState();
    try {
      const result = await uploadsApi.uploadCertificateTemplate(file);
      setCheck(result.template_check);
      setSignedId(result.signed_id);
      onChange(result.url);
    } catch (e: any) {
      setError(e.message ?? t("certificateTemplate.uploadFailed"));
    } finally {
      setUploading(false);
    }
  }

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (file) handleFile(file);
    // Clear the input so re-picking the *same* file after an edit still fires
    // a change event — the common case when an organizer fixes their template
    // in LibreOffice and uploads it again under the same name.
    e.target.value = "";
  }

  async function startPreview() {
    if (!signedId) return;

    const generation = ++generationRef.current;
    setPreviewing(true);
    setPreviewError(null);
    setPreview(null);

    try {
      const { preview: started } = await certificatePreviewApi.request(eventId, signedId);
      if (generationRef.current !== generation) return;
      setPreview(started);
      poll(generation, Date.now());
    } catch (e: any) {
      if (generationRef.current !== generation) return;
      setPreviewing(false);
      setPreviewError(e.message ?? t("certificateTemplate.previewFailed"));
    }
  }

  function poll(generation: number, startedAt: number) {
    timerRef.current = setTimeout(async () => {
      if (generationRef.current !== generation) return;

      try {
        const { preview: latest } = await certificatePreviewApi.get(eventId);
        if (generationRef.current !== generation) return;

        if (latest && latest.status !== "pending") {
          setPreview(latest);
          setPreviewing(false);
          if (latest.status === "failed") {
            setPreviewError(
              t(`certificateTemplate.previewError.${latest.error_code ?? "unknown"}`, {
                defaultValue: t("certificateTemplate.previewFailed"),
              }),
            );
          }
          return;
        }

        if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
          // Give up rather than poll forever. The render may still land — the
          // row is there and a later visit will show it — but an organizer
          // watching a spinner indefinitely deserves to be told.
          setPreviewing(false);
          setPreviewError(t("certificateTemplate.previewTimeout"));
          return;
        }

        poll(generation, startedAt);
      } catch {
        if (generationRef.current !== generation) return;
        setPreviewing(false);
        setPreviewError(t("certificateTemplate.previewFailed"));
      }
    }, POLL_MS);
  }

  const hasSplitTokens = check != null && check.split.length > 0;

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
            {signedId && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={startPreview}
                disabled={previewing || uploading}
              >
                {previewing ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <>
                    <Eye className="h-4 w-4" /> {t("certificateTemplate.preview")}
                  </>
                )}
              </Button>
            )}
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
              onClick={() => {
                resetTemplateState();
                setCheck(null);
                setSignedId(null);
                onChange(null);
              }}
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

      {/* Token check — always shown once a template has been inspected. */}
      {check && (
        <div
          className={`rounded-xl border p-3 text-xs space-y-1.5 ${
            hasSplitTokens
              ? "border-destructive/40 bg-destructive/5"
              : "border-border bg-muted/20"
          }`}
        >
          <p className="flex items-center gap-1.5 font-medium text-foreground">
            {hasSplitTokens ? (
              <AlertTriangle className="h-3.5 w-3.5 text-destructive" />
            ) : (
              <CheckCircle2 className="h-3.5 w-3.5 text-primary" />
            )}
            {hasSplitTokens
              ? t("certificateTemplate.checkSplitTitle")
              : t("certificateTemplate.checkOkTitle", { found: check.present.length })}
          </p>

          {hasSplitTokens && (
            <p className="text-destructive">
              {t("certificateTemplate.checkSplitBody", {
                tokens: check.split.map((token) => `{{${token}}}`).join(", "),
              })}
            </p>
          )}

          {check.missing.length > 0 && !hasSplitTokens && (
            <p className="text-muted-foreground">
              {t("certificateTemplate.checkMissing", {
                tokens: check.missing.map((token) => `{{${token}}}`).join(", "),
              })}
            </p>
          )}
        </div>
      )}

      {/* Rendered preview. */}
      {previewing && (
        <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
          {t("certificateTemplate.previewRendering")}
        </p>
      )}

      {previewError && <p className="text-xs text-destructive">{previewError}</p>}

      {preview?.status === "ready" && preview.file_url && (
        <div className="space-y-2">
          {/* An <object> rather than an <img>: the render is a PDF, which is
              what the participant actually receives. Rasterising it to an
              image server-side would be another dependency and another way
              for the preview to differ from the real thing. */}
          <object
            data={preview.file_url}
            type="application/pdf"
            className="h-[320px] w-full rounded-xl border border-border bg-muted/20"
            aria-label={t("certificateTemplate.previewAlt")}
          >
            {/* Shown when the browser has no inline PDF viewer, which is most
                mobile browsers — so this is the normal path on a phone, not
                an error case. */}
            <p className="p-3 text-xs text-muted-foreground">
              {t("certificateTemplate.previewNoInlineViewer")}
            </p>
          </object>
          <a
            href={preview.file_url}
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs text-primary underline underline-offset-2"
          >
            {t("certificateTemplate.previewOpenInNewTab")}
          </a>
        </div>
      )}

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
