import { cn } from "@/lib/utils";

interface HeroBannerProps {
  src: string;
  alt: string;
  /** Tailwind height classes for the strip. Defaults to the event-detail size. */
  className?: string;
  /**
   * The fade into the page below. On by default, because that is what the two
   * public pages want; off for the upload preview, where there is no page
   * underneath to fade into and the darkening would misrepresent the image.
   */
  fadeOut?: boolean;
}

/**
 * A full-bleed banner strip that shows the **whole** uploaded image.
 *
 * Both this page and the organizer profile previously did
 * `<img className="h-full w-full object-cover">` in a fixed-height strip.
 * `object-cover` fills the strip by cropping whatever doesn't fit, so a banner
 * designed at one ratio and viewed at another loses its top and bottom — on a
 * wide monitor that meant headline text and logos sliced in half. Organizers
 * design these carefully, and the page was silently discarding the edges.
 *
 * So: two layers of the same image.
 *
 *   - **Behind**, `object-cover` and heavily blurred — fills the strip edge to
 *     edge so there is never a hard letterbox bar, and reads as an extension of
 *     the artwork because it is literally made of the same pixels.
 *   - **In front**, `object-contain` and centred — the complete design, never
 *     cropped, never distorted.
 *
 * `scale-110` on the backdrop is load-bearing, not decoration: a large blur
 * radius samples past the element's edges, which leaves a visibly lighter rim
 * around the strip. Over-scaling pushes that artifact outside the overflow
 * clip.
 *
 * The blur layer is `aria-hidden` and the real one carries the alt text, so a
 * screen reader hears one image rather than the same thing twice.
 */
export function HeroBanner({ src, alt, className, fadeOut = true }: HeroBannerProps) {
  return (
    <div className={cn("relative w-full overflow-hidden bg-muted", className ?? "h-52 md:h-72")}>
      <img
        src={src}
        alt=""
        aria-hidden="true"
        className="absolute inset-0 h-full w-full scale-110 object-cover blur-2xl"
      />
      {/* Knocks back the backdrop so it reads as atmosphere rather than
          competing with the real banner in front of it. */}
      <div className="absolute inset-0 bg-background/40" />
      <img src={src} alt={alt} className="relative h-full w-full object-contain" />
      {fadeOut && (
        <div className="absolute inset-0 bg-gradient-to-t from-background/80 to-transparent" />
      )}
    </div>
  );
}
