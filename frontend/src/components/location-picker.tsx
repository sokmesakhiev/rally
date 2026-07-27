/**
 * LocationPicker — search-as-you-type Google Places autocomplete plus a
 * draggable pin, used on the create-event form.
 *
 * Gracefully degrades: without VITE_GOOGLE_MAPS_API_KEY configured, this
 * renders a plain text input instead (no map, no coordinates) so event
 * creation still works. See .env.example.
 */
import { useEffect, useId, useRef, useState } from "react";
import { importLibrary, setOptions } from "@googlemaps/js-api-loader";
import { useTranslation } from "react-i18next";
import { Loader2, MapPin } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const GOOGLE_MAPS_API_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY as string | undefined;

// setOptions() must only be called once, before the first importLibrary()
// call — guard against StrictMode's double-invoke and multiple mounted
// pickers (e.g. if this were ever used twice on one page) calling it again.
let optionsConfigured = false;
function configureLoaderOnce() {
  if (optionsConfigured || !GOOGLE_MAPS_API_KEY) return;
  setOptions({ key: GOOGLE_MAPS_API_KEY, v: "weekly" });
  optionsConfigured = true;
}

export interface LocationValue {
  location: string;
  latitude: number | null;
  longitude: number | null;
}

interface LocationPickerProps {
  value: LocationValue;
  onChange: (value: LocationValue) => void;
}

// Phnom Penh — just a sane starting point for the map before anything is
// searched or dropped; never saved unless the organizer actually picks a spot.
const DEFAULT_CENTER = { lat: 11.5564, lng: 104.9282 };

export function LocationPicker({ value, onChange }: LocationPickerProps) {
  const { t } = useTranslation();
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const mapDivRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<google.maps.Map | null>(null);
  const markerRef = useRef<google.maps.Marker | null>(null);
  // Read inside the effect via a ref so the setup effect doesn't need
  // `onChange`/`value` in its dependency array (it must only run once).
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");

  useEffect(() => {
    if (!GOOGLE_MAPS_API_KEY || !inputRef.current || !mapDivRef.current) return;
    let cancelled = false;
    configureLoaderOnce();

    Promise.all([importLibrary("places"), importLibrary("maps"), importLibrary("marker")])
      .then(([{ Autocomplete }, { Map }, { Marker }]) => {
        if (cancelled || !inputRef.current || !mapDivRef.current) return;

        const hasPoint = value.latitude != null && value.longitude != null;
        const startCenter = hasPoint
          ? { lat: value.latitude!, lng: value.longitude! }
          : DEFAULT_CENTER;

        const map = new Map(mapDivRef.current, {
          center: startCenter,
          zoom: hasPoint ? 14 : 11,
          disableDefaultUI: true,
          zoomControl: true,
        });
        mapRef.current = map;

        const marker = new Marker({
          map,
          position: startCenter,
          draggable: true,
          visible: hasPoint,
        });
        markerRef.current = marker;

        marker.addListener("dragend", () => {
          const pos = marker.getPosition();
          if (!pos) return;
          onChangeRef.current({
            location: inputRef.current?.value ?? "",
            latitude: pos.lat(),
            longitude: pos.lng(),
          });
        });

        const autocomplete = new Autocomplete(inputRef.current, {
          fields: ["formatted_address", "geometry", "name"],
        });
        autocomplete.addListener("place_changed", () => {
          const place = autocomplete.getPlace();
          const point = place.geometry?.location;
          const address = place.formatted_address ?? place.name ?? inputRef.current?.value ?? "";

          if (point) {
            map.panTo(point);
            map.setZoom(15);
            marker.setPosition(point);
            marker.setVisible(true);
            onChangeRef.current({
              location: address,
              latitude: point.lat(),
              longitude: point.lng(),
            });
          } else {
            // Free text with no matched place — keep the label, drop any stale pin.
            onChangeRef.current({ location: address, latitude: null, longitude: null });
          }
        });

        setStatus("ready");
      })
      .catch(() => {
        if (!cancelled) setStatus("error");
      });

    return () => {
      cancelled = true;
    };
    // Intentionally runs once per mount only — re-running on every keystroke
    // would tear down and rebuild the map/autocomplete/marker instances.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Keep the pin in sync if `value` is changed from outside this component
  // (e.g. the form resetting) after the map has already loaded.
  useEffect(() => {
    if (status !== "ready" || !markerRef.current || !mapRef.current) return;
    if (value.latitude == null || value.longitude == null) {
      markerRef.current.setVisible(false);
      return;
    }
    const pos = { lat: value.latitude, lng: value.longitude };
    markerRef.current.setPosition(pos);
    markerRef.current.setVisible(true);
    mapRef.current.panTo(pos);
  }, [status, value.latitude, value.longitude]);

  if (!GOOGLE_MAPS_API_KEY) {
    return (
      <div className="space-y-2">
        <Label htmlFor={inputId}>{t("eventForm.location")}</Label>
        <Input
          id={inputId}
          value={value.location}
          onChange={(e) => onChange({ location: e.target.value, latitude: null, longitude: null })}
          placeholder={t("eventForm.locationPlaceholder")}
        />
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <Label htmlFor={inputId}>{t("eventForm.location")}</Label>
      <div className="relative">
        <MapPin className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        {/* Uncontrolled on purpose: Google's Autocomplete widget writes
            straight into the input's DOM value when a suggestion is picked,
            which would fight a React-controlled `value`. */}
        <Input
          ref={inputRef}
          id={inputId}
          defaultValue={value.location}
          onChange={(e) => onChange({ location: e.target.value, latitude: null, longitude: null })}
          placeholder={t("eventForm.locationPlaceholder")}
          className="pl-9"
          autoComplete="off"
        />
        {status === "loading" && (
          <Loader2 className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-muted-foreground" />
        )}
      </div>
      {status === "error" && (
        <p className="text-xs text-destructive">{t("eventForm.mapLoadError")}</p>
      )}
      <div
        ref={mapDivRef}
        className="h-48 w-full overflow-hidden rounded-lg border border-border bg-muted"
      />
      <p className="text-xs text-muted-foreground">{t("eventForm.mapHint")}</p>
    </div>
  );
}
