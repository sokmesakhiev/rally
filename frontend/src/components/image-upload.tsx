import { useRef, useState } from "react";
import { Upload, X, Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { uploadsApi } from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { HeroBanner } from "@/components/hero-banner";

interface ImageUploadProps {
  value: string | null;
  onChange: (url: string | null) => void;
  /** "banner" renders as a wide strip; "logo"/"avatar" render as a square. */
  variant?: "banner" | "logo" | "avatar";
  label?: string;
  /**
   * Suppresses the recommended-size hint under a banner. Only for places where
   * the surrounding form already says it — otherwise leave it on: organizers
   * had no way at all to know what ratio to design for, which is how banners
   * came to be uploaded at shapes the page had to letterbox.
   */
  hideSizeHint?: boolean;
}

/**
 * What to design a banner at. Derived from where banners actually render —
 * HeroBanner's strip is 288px tall on desktop, so at a typical 1280–1600px
 * viewport a 4:1 image fills it almost exactly and the blurred edges stay
 * thin. Wildly different ratios still *work* (HeroBanner shows the whole
 * image and blurs the gap rather than cropping), they just leave more blur.
 */
export const BANNER_RECOMMENDED_WIDTH = 1600;
export const BANNER_RECOMMENDED_HEIGHT = 400;

export function ImageUpload({
  value,
  onChange,
  variant = "banner",
  label,
  hideSizeHint = false,
}: ImageUploadProps) {
  const { t } = useTranslation();
  const inputRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isLogo = variant !== "banner";

  async function handleFile(file: File) {
    setError(null);
    setUploading(true);
    try {
      const url = await uploadsApi.upload(file, variant);
      onChange(url);
    } catch (e: any) {
      setError(e.message ?? t("imageUpload.uploadFailed"));
    } finally {
      setUploading(false);
    }
  }

  function handleDrop(e: React.DragEvent) {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (file) handleFile(file);
  }

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (file) handleFile(file);
  }

  return (
    <div className="space-y-2">
      {label && <p className="text-sm font-medium">{label}</p>}
      <div
        className={cn(
          "relative overflow-hidden border-2 border-dashed border-border bg-muted/40 transition-colors hover:border-primary/50",
          variant === "avatar" ? "rounded-full" : "rounded-xl",
          isLogo ? "h-24 w-24" : "h-36 w-full",
          uploading && "pointer-events-none opacity-60",
        )}
        onDragOver={(e) => e.preventDefault()}
        onDrop={handleDrop}
        onClick={() => inputRef.current?.click()}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => e.key === "Enter" && inputRef.current?.click()}
      >
        {value ? (
          <>
            {isLogo ? (
              <img
                src={value}
                alt={t("imageUpload.previewAlt")}
                className="h-full w-full object-cover"
              />
            ) : (
              /* The same component the public pages use, so this preview is
                 the real rendering rather than an approximation of it. An
                 object-cover preview would crop where the live page doesn't,
                 leaving the organizer to judge a picture nobody will see. */
              <HeroBanner
                src={value}
                alt={t("imageUpload.previewAlt")}
                className="h-full"
                fadeOut={false}
              />
            )}
            {/* Remove button */}
            <button
              type="button"
              className="absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full bg-black/60 text-white hover:bg-black/80"
              onClick={(e) => {
                e.stopPropagation();
                onChange(null);
              }}
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </>
        ) : (
          <div className="flex h-full flex-col items-center justify-center gap-1.5 p-3 text-center text-muted-foreground">
            {uploading ? (
              <Loader2 className="h-5 w-5 animate-spin" />
            ) : (
              <>
                <Upload className="h-5 w-5" />
                {!isLogo && <p className="text-xs">{t("imageUpload.clickOrDrag")}</p>}
              </>
            )}
          </div>
        )}
      </div>
      {!isLogo && !hideSizeHint && (
        <p className="text-xs text-muted-foreground">
          {t("imageUpload.bannerSizeHint", {
            width: BANNER_RECOMMENDED_WIDTH,
            height: BANNER_RECOMMENDED_HEIGHT,
          })}
        </p>
      )}
      {error && <p className="text-xs text-destructive">{error}</p>}
      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp,image/gif"
        className="hidden"
        onChange={handleChange}
      />
    </div>
  );
}
