# Frontend UI: tab bar, banners, and the gated Google integrations

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Frontend: Google Identity Services sign-in

`GoogleSignInButton` (`src/components/google-sign-in-button.tsx`), rendered on `auth.tsx`, wraps Google's official Identity Services "Sign in with Google" button. Unlike the Google Maps integration, it loads Google's `<script src="https://accounts.google.com/gsi/client">` directly rather than an npm package — no new frontend dependency.

- **Gated behind `VITE_GOOGLE_CLIENT_ID`** (see `.env.example`), same fallback philosophy as `LocationPicker`: unset, the component renders `null` and `auth.tsx` hides the button + "or with email" divider entirely, leaving email/password as the only sign-in path. Must be the same Client ID as the backend's `GOOGLE_CLIENT_ID` (`infrastructure/variables.tf`'s `google_client_id` — not a secret, it's compiled into the frontend bundle either way).
- On credential (an ID token, not an access token), the button's callback calls `authApi.google(idToken)` → `POST /api/v1/auth/google`, which does all real verification server-side — the frontend never validates or trusts the token itself.

### Frontend: reCAPTCHA v3 on signup

`getRecaptchaToken()` (`src/lib/recaptcha.ts`), called from `auth.tsx`'s `handleSignUp` right before `authApi.signup`, gets an invisible reCAPTCHA v3 token scoped to the `"signup"` action and sends it as `recaptcha_token`. Like `GoogleSignInButton`, it loads Google's `<script src="https://www.google.com/recaptcha/api.js?render=...">` directly rather than an npm package.

- **Gated behind `VITE_RECAPTCHA_SITE_KEY`** (see `.env.example`) — unset, `getRecaptchaToken()` resolves to `undefined` immediately with no script ever loaded, and signup still works with no captcha check (the backend only enforces verification once `RECAPTCHA_SECRET_KEY` is also set — see "Backend: Rails API, JWT auth, no sessions" above). Both sides must be configured for the check to actually run; setting only one has no effect.
- Sign-in and sign-up are otherwise plain `<form onSubmit>`s (not just `<Button onClick>`s) so pressing Enter in a field submits, same as clicking the button.
- The sign-up form also validates a "confirm password" field client-side (`validateSignUp` in `auth.tsx`) before ever calling `authApi.signup` — there's no matching server-side confirmation param; the backend only ever sees the one `password` value.

### Frontend: the manage-event tab bar

`dashboard_.events.$eventId.tsx` has nine panels but only **four top-level tabs** — Participants, Check-in, Results, Setup — plus a "More" dropdown. Branding, Registration and Certificate live inside Setup behind a nested `Tabs` (a separate Radix root, so keyboard and ARIA behaviour matches); Survey Responses, Activity Logs and Members sit in the overflow menu.

- **The grid it replaced was structurally fragile.** `TabsList` was `grid grid-cols-N` with `N` looked up from a hand-maintained `TAB_GRID_CLASSES` table keyed on `visibleTabKeys.length`. Adding a trigger without adding a matching key silently sized the grid one column short and the last tab wrapped onto its own row — which is exactly what happened when the Registration tab was added gated on `tabVisibility.certificate`. Auto-width triggers in a flex row have no count to keep in sync.
- **Nine tabs never fit anyway**: measured at 1048px of labels inside an 856px container. Four tabs plus More is 544px.
- **The Setup sub-nav is underlined, not pills, and that is the whole point of it.** It first shipped with the default `TabsList` styling, which made it byte-for-byte the same control as the bar above it: two identical trays of pills, stacked, with nothing saying one was subordinate to the other. Filled pill for the primary level and underline for the secondary is the conventional pairing. `SETUP_TABS_LIST_CLASS`/`SETUP_TAB_TRIGGER_CLASS` override shadcn's defaults **at the call site** rather than editing `components/ui/tabs.tsx`, which stays vendored; `-mb-px` on the trigger pulls its `border-b-2` onto the list's rule so the active underline sits *in* the divider. Active state is colour plus underline and deliberately **not** a weight change — bolding the label widens it and shunts every tab after it sideways.
- **`panelVisibility` is per-panel; a group renders only when something inside it does.** Otherwise a Viewer (no `update_event`) would get a Setup tab containing nothing. `setupPanels`/`overflowPanels` are the filtered lists, and their emptiness is what hides Setup and More respectively. The Check-in role still sees exactly Participants and Check-in and nothing else, which is that role's acceptance criterion.
- **The Tabs root is controlled (`value`/`onValueChange`), not `defaultValue`.** The overflow items are `DropdownMenuItem`s, not `TabsTrigger`s, so selecting one has to set the value directly. The dropdown trigger deliberately sits **outside** `TabsList` — a non-trigger child inside it breaks Radix's roving focus — and shows the active overflow panel's label so the bar still indicates what's open.

### Frontend: banners

`HeroBanner` (`src/components/hero-banner.tsx`) is the full-bleed strip on the event detail and organizer profile pages, and the preview inside `ImageUpload`. All three go through it so they cannot drift — the event and organizer pages previously carried byte-identical `object-cover` markup, and a preview that crops differently from the live page is worse than no preview.

- **`object-cover` was the bug.** It fills a fixed-height strip by cropping whatever doesn't fit, so a banner designed at one ratio and viewed at another lost its top and bottom — on a wide monitor, headline text and sponsor strips sliced in half. Organizers design these deliberately and the page was silently discarding the edges.
- **Two layers of the same image**: behind, `object-cover` blurred and `scale-110`; in front, `object-contain` centred. The blur means there is never a hard letterbox bar, and it reads as an extension of the artwork because it is literally the same pixels. **The `scale-110` is load-bearing** — a large blur radius samples past the element's edges and leaves a lighter rim otherwise; over-scaling pushes that artifact outside the overflow clip. The backdrop is `aria-hidden` with empty alt so a screen reader hears one image, not two.
- **Recommended banner size is 1600 × 400 (4:1)**, exported as `BANNER_RECOMMENDED_WIDTH`/`HEIGHT` and shown under the dropzone. Derived from the strip being 288px tall on desktop: at a 1280–1600px viewport a 4:1 image fills it almost exactly, leaving ~64px of blur per side. Other ratios still work — nothing is cropped, there is just more blur. (The old `ImageUpload` prop comment claimed "a wide 16:5 container", which was never true of the markup; there was no accurate size guidance anywhere before this.)

### Frontend: Google Maps location picker

`LocationPicker` (`src/components/location-picker.tsx`), used on the create-event form (`events.new.tsx`), is a search-as-you-type Places Autocomplete input plus a draggable pin on an embedded map. It's built on `@googlemaps/js-api-loader`'s v2 functional API (`setOptions()` once, then `importLibrary("places" | "maps" | "marker")`), not the older `Loader` class.

- **Gated entirely behind `VITE_GOOGLE_MAPS_API_KEY`** (see `.env.example`). Without it, `LocationPicker` renders a plain text `<Input>` instead — no map, no autocomplete, `latitude`/`longitude` stay `null` — so event creation still works with zero Google Cloud setup. Don't assume the key is present when touching this component.
- The text input is deliberately **uncontrolled** (`defaultValue`, not `value`) once the map key is present — Google's `Autocomplete` widget writes directly into the input's DOM value when a suggestion is picked, which would fight a React-controlled value. The authoritative source for the selected address is the `place_changed` listener, not the input's `onChange` (which only tracks manual free-typing between selections).
- Uses the classic `google.maps.Marker` (via `importLibrary("marker")`), not `AdvancedMarkerElement` — the latter needs a Cloud Console "Map ID" to be configured, which is one more setup step this intentionally avoids.
- `tsconfig.json`'s `compilerOptions.types` explicitly includes `"google.maps"` (alongside `"vite/client"`) — without that, `@types/google.maps`'s global `google` namespace won't resolve even though the package is installed, since `types` being present at all restricts automatic global type inclusion to just what's listed.
- `googleMapsViewUrl()` in `event-utils.ts` builds a plain `https://www.google.com/maps?q=lat,lng` link for the "View on map" links on the event detail/manage pages — this needs no API key at all (it's just an outbound link, not an embed), so those pages work regardless of whether `VITE_GOOGLE_MAPS_API_KEY` is configured.
