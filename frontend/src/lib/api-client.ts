/**
 * Rails API client — replaces all Supabase queries.
 * Base URL reads from VITE_API_URL (defaults to http://localhost:3001).
 */

const RAW_API_URL =
  typeof import.meta !== "undefined"
    ? (import.meta.env?.VITE_API_URL ?? "http://localhost:3001")
    : (process.env.API_URL ?? "http://localhost:3001");

// VITE_API_URL is concatenated straight into fetch() calls below with no
// URL normalization — a value missing "http://"/"https://" (e.g. someone
// building with VITE_API_URL="rally-api.rails-dev.com" instead of
// "https://rally-api.rails-dev.com") doesn't fail, it silently produces a
// *relative* URL that the browser resolves against the current page's own
// origin instead of the API host. Fail loudly at build/boot time instead.
if (!/^https?:\/\//.test(RAW_API_URL)) {
  throw new Error(
    `VITE_API_URL must include a scheme (http:// or https://), got: "${RAW_API_URL}"`,
  );
}

const BASE_URL = RAW_API_URL + "/api/v1";

const TOKEN_KEY = "rally_token";

/**
 * A staff support session lives in its own key, and `rally_token` is never
 * touched while one is open.
 *
 * The obvious implementation — overwrite `rally_token`, stash the old one,
 * restore it on exit — has an obvious failure: a crash, a closed tab, or a
 * refresh at the wrong moment logs the admin out of their *own* account, and
 * the recovery is a password sign-in. An admin must always be able to leave an
 * impersonated session, and the way to guarantee that is to never have left
 * their own. Exiting is one `removeItem`.
 */
const IMPERSONATION_TOKEN_KEY = "rally_impersonation_token";

// ─── Token helpers ────────────────────────────────────────────────────────────

/** Prefers the impersonation token when one is present, so every existing
 *  caller is impersonation-aware without knowing it. */
export function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem(IMPERSONATION_TOKEN_KEY) ?? localStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string): void {
  if (typeof window !== "undefined") localStorage.setItem(TOKEN_KEY, token);
}

export function clearToken(): void {
  if (typeof window !== "undefined") localStorage.removeItem(TOKEN_KEY);
}

export function getImpersonationToken(): string | null {
  return typeof window !== "undefined" ? localStorage.getItem(IMPERSONATION_TOKEN_KEY) : null;
}

export function setImpersonationToken(token: string): void {
  if (typeof window !== "undefined") localStorage.setItem(IMPERSONATION_TOKEN_KEY, token);
}

export function clearImpersonationToken(): void {
  if (typeof window !== "undefined") localStorage.removeItem(IMPERSONATION_TOKEN_KEY);
}

/** The admin's own token, ignoring any impersonation in progress. Ending a
 *  session is an admin action and a write — both refused under an
 *  impersonation token — so it has to be sent with this. */
export function getOwnToken(): string | null {
  return typeof window !== "undefined" ? localStorage.getItem(TOKEN_KEY) : null;
}

// ─── Core fetch wrapper ───────────────────────────────────────────────────────

/** Thrown on any non-2xx API response. `code` is an optional machine-readable
 * error identifier some endpoints return alongside the human-readable
 * message (e.g. "full" for a capacity error) — see individual API methods
 * for which codes they can produce. */
export class ApiError extends Error {
  code?: string;
  constructor(message: string, code?: string) {
    super(message);
    this.name = "ApiError";
    this.code = code;
  }
}

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  isFormData = false,
  /** Send the admin's own credentials rather than the impersonation token.
   *  Only the impersonation endpoints need this — see getOwnToken. */
  useOwnToken = false,
): Promise<T> {
  const headers: Record<string, string> = {};
  const token = useOwnToken ? getOwnToken() : getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  if (!isFormData) headers["Content-Type"] = "application/json";

  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: isFormData ? (body as FormData) : body ? JSON.stringify(body) : undefined,
  });

  const text = await res.text();
  const json = text ? JSON.parse(text) : {};

  if (!res.ok) {
    throw new ApiError(json.error ?? `API error ${res.status}`, json.code);
  }

  return json as T;
}

const api = {
  get: <T>(path: string) => request<T>("GET", path),
  post: <T>(path: string, body?: unknown) => request<T>("POST", path, body),
  patch: <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
  delete: <T>(path: string, body?: unknown) => request<T>("DELETE", path, body),
  upload: <T>(path: string, form: FormData) => request<T>("POST", path, form, true),
  asAdmin: {
    get: <T>(path: string) => request<T>("GET", path, undefined, false, true),
    post: <T>(path: string, body?: unknown) => request<T>("POST", path, body, false, true),
    delete: <T>(path: string) => request<T>("DELETE", path, undefined, false, true),
  },
};

/**
 * Fetches a file from an authenticated endpoint and triggers a browser
 * download. A plain `<a href>` can't carry the JWT (it lives in
 * localStorage, not a cookie), so any download that requires auth goes
 * through fetch + a Blob object URL instead of a direct link.
 *
 * The filename is read from the response's Content-Disposition header (set
 * by the Rails `send_data` call) when present, falling back to
 * `fallbackFilename` otherwise.
 */
async function downloadFile(path: string, fallbackFilename: string): Promise<void> {
  const headers: Record<string, string> = {};
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${BASE_URL}${path}`, { method: "GET", headers });

  if (!res.ok) {
    // Error responses are JSON ({ error, code? }), same shape as the rest
    // of the API — only the happy path is a raw file.
    const text = await res.text();
    let message = `API error ${res.status}`;
    let code: string | undefined;
    try {
      const parsed = JSON.parse(text);
      message = parsed.error ?? message;
      code = parsed.code;
    } catch {
      // Response wasn't JSON — keep the generic message.
    }
    throw new ApiError(message, code);
  }

  const blob = await res.blob();
  const disposition = res.headers.get("Content-Disposition") ?? "";
  const filenameMatch = disposition.match(/filename="?([^";]+)"?/);
  const filename = filenameMatch?.[1] ?? fallbackFilename;

  const objectUrl = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = objectUrl;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(objectUrl);
}

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ApiUser {
  id: string;
  email: string;
  /** True for a phone-only guest checkout (see registrationsApi.create) —
   * `email` above is an auto-generated "guest-...@guest.rally.invalid"
   * placeholder, not a real address. Show `phone` instead where possible,
   * and prompt to add a real email rather than displaying this one. */
  email_auto_generated: boolean;
  phone: string | null;
  display_name: string | null;
  avatar_url: string | null;
  email_verified: boolean;
  /** Admin-granted organizer verification — NOT the same as email_verified
   * above, which is self-service. Gates creating paid events. Like `admin`,
   * this only drives UI affordances; EventsController re-checks server-side. */
  verified: boolean;
  /** Drives whether the admin nav link renders. NOT a security boundary —
   * every admin endpoint re-checks server-side. */
  admin?: boolean;
  /** Null means this account has never accepted the Terms of Service — true
   * for a brand-new Google sign-in (that flow never shows a checkbox, unlike
   * email/password signup). Drives the one-time acceptance interstitial in
   * auth.tsx's handleGoogleCredential — see
   * event-freeze-and-terms-tickets.md's Ticket H. Not a security boundary;
   * nothing server-side is blocked on it. */
  terms_accepted_at: string | null;
  created_at: string;
}

export type SurveyQuestionType = "text" | "single_choice" | "multiple_choice";

export interface ApiSurveyOption {
  id: string;
  label: string;
}

export interface ApiSurveyQuestion {
  id: string;
  survey_id: string;
  question_text: string;
  question_type: SurveyQuestionType;
  options: ApiSurveyOption[];
  position: number;
  required: boolean;
}

export interface ApiSurvey {
  id: string;
  creator_id: string;
  title: string;
  questions: ApiSurveyQuestion[];
  questions_count?: number;
  created_at: string;
  updated_at: string;
}

export interface ApiRegistrationAnswer {
  survey_question_id: string;
  answer_text?: string;
  answer_options?: string[];
}

/** Pagination envelope returned alongside paginated lists. */
export interface ApiPageMeta {
  page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
}

/** Registrations::Summary on the backend — counts and revenue over the whole
 *  event, independent of whichever page of the list is on screen. */
export interface ApiRegistrationSummary {
  total: number;
  paid: number;
  unpaid: number;
  checked_in: number;
  revenue_cents: number;
  /** event_type id -> registered count, with every type present (zero when
   *  nobody has picked it), so callers needn't guard for missing keys. */
  by_event_type: Record<string, number>;
}

export interface ApiEventType {
  id: string;
  event_id: string;
  name: string;
  description: string | null;
  capacity: number | null; // null = unlimited per type
  price_cents: number | null; // null = inherit event price
  position: number;
  spots_remaining: number | null; // null = unlimited
}

export interface ApiEventTypeDraft {
  name: string;
  description?: string;
  capacity?: number | null;
  price_cents?: number | null;
  position: number;
}

/** Pagination envelope returned alongside paginated collections. */
export interface ApiPageMeta {
  page: number;
  per_page: number;
  total_count: number;
  /** 0 when nothing matched, so `page > total_pages` is a safe emptiness check. */
  total_pages: number;
}

export interface ApiEvent {
  id: string;
  creator_id: string;
  survey_id: string | null;
  survey?: ApiSurvey;
  event_types: ApiEventType[];
  title: string;
  description: string | null;
  category: string;
  location: string | null;
  /** Set by the Google Maps location picker; null if the organizer never
   * picked a point (or the picker fell back to plain text — no API key). */
  latitude: number | null;
  longitude: number | null;
  /** Optional Google My Maps / Maps route link for point-to-point events. */
  route_map_url: string | null;
  start_at: string;
  end_at: string | null;
  capacity: number | null;
  /** Pricing tier this event published under — set once, via publishing. Null while a draft. */
  plan: string | null;
  price_cents: number;
  currency: string;
  is_published: boolean;
  /** Whether a published event appears in the public catalogue and search.
   *  Orthogonal to `is_published` — an "unlisted" event is fully live and
   *  takes registrations, it just isn't listed. Access is the URL: anyone
   *  holding the link can view and register, and a forwarded link works for
   *  whoever receives it, so don't present this to an organizer as access
   *  control. */
  visibility: "public" | "unlisted";
  /** True when the organizer closed sign-ups, or a deadline they set has
   *  passed. Distinct from "full": a closed event may have plenty of spots,
   *  and unlike a full one it offers no waitlist. */
  registration_closed: boolean;
  registration_closed_at: string | null;
  /** An announced deadline. Shown to participants *before* it passes so they
   *  know to hurry, and it stays meaningful afterwards as the reason. */
  registration_closes_at: string | null;
  /** The organization presenting this event — distinct from creator_id, which
   * is the individual who set it up. Required when creating. */
  organization_id: string;
  /** Enough to render the "Presented by" block and link through. The full
   * public profile — trust signals, contact details, their other events —
   * comes from organizerApi. */
  organization: {
    slug: string;
    name: string;
    logo_url: string | null;
    verified: boolean;
  } | null;
  /** True once an admin has suspended this event (event-freeze-and-terms-tickets.md,
   * Ticket A) — stronger than is_published: false, since the owner cannot
   * reverse it themselves (every mutating action 403s server-side while
   * suspended). `suspension_reason`/`suspended_at` are only meaningful when this is true. */
  suspended: boolean;
  suspension_reason: string | null;
  suspended_at: string | null;
  brand_color: string;
  banner_url: string | null;
  logo_url: string | null;
  /** Organizer-uploaded .odt certificate-of-participation template. Null
   * means the feature is off for this event — no certificates are generated. */
  certificate_template_url: string | null;
  created_at: string;
  updated_at: string;
  registrations_count?: number;
  /** The caller's relationship to this event: "owner" (the creator), one of
   * EventMembership::ROLES ("manager"/"check_in"/"viewer"), or null if the
   * caller has none (an anonymous viewer, or a signed-in stranger). Present
   * on both eventsApi.get() (GET /events/:id) and eventsApi.myEvents() (GET
   * /events/my) — see Api::V1::EventsController#show/#my_events. Purely a
   * UI affordance for role-aware chrome (see event-membership-tickets.md,
   * Ticket G) — same caveat as PaidEventGate: the server re-checks
   * everything on every actual write. */
  role?: "owner" | "manager" | "check_in" | "viewer" | null;
}

export interface ApiWaitlistEntry {
  id: string;
  event_id: string;
  user_id: string;
  event_type_ids: string[];
  status: "waiting" | "promoted" | "cancelled";
  created_at: string;
  event?: { id: string; title: string; start_at: string };
  /** Only present on the organizer's view (GET /events/:id/waitlist_entries) — 1-based queue position. */
  position?: number;
  email?: string;
  profile?: { display_name: string | null; avatar_url: string | null };
}

export interface ApiRegistration {
  id: string;
  event_id: string;
  user_id: string;
  status: string;
  payment_status: string;
  amount_paid_cents: number;
  created_at: string;
  /** Null until an organizer scans/taps this registration in on event day. */
  checked_in_at: string | null;
  /** Race number, null until an organizer assigns one. A string, not a
   * number — real bibs look like "A1042" or "0007", where the leading zeros
   * are printed on the bib itself. */
  bib_number: string | null;
  event?: ApiEvent;
  event_types: ApiEventType[];
  profile?: { display_name: string | null; avatar_url: string | null };
  /** Present only once GenerateCertificatesJob has rendered a PDF for this
   * registration (event ended + registration confirmed & paid + the event
   * has a template) — absent (not just null) until then. */
  certificate_url?: string;
  /** Present only once an organizer has recorded a finish time (manually
   * or via CSV import) — absent (not just null) until then. Optional, most
   * event types (a social gathering, an untimed ride) never get one. */
  finish_time_seconds?: number;
}

export interface ApiProfile {
  id: string | null;
  user_id: string;
  display_name: string | null;
  avatar_url: string | null;
  phone: string | null;
  /** See ApiUser.email_auto_generated — same signal, surfaced here too
   * since profile.tsx loads this endpoint rather than /auth/me. */
  email_auto_generated: boolean;
  /** Never the plaintext key — see payway_api_key_masked. Both identifiers
   *  come back null in a staff support session; `payway_hidden` is how you
   *  tell that apart from "nothing saved yet", which is a different fact and
   *  a different empty state. */
  payway_merchant_id: string | null;
  payway_api_key_masked: string | null;
  /** True only during a staff support session (see the impersonation design).
   *  The booleans below stay truthful either way — whether a credential exists
   *  is not the credential. */
  payway_hidden: boolean;
  payway_configured: boolean;
  /** Opt-out notification preferences — all default true. Only cover
   * RegistrationMailer's non-essential emails; password resets, email
   * verification, and the initial registration confirmation are always sent. */
  notify_payment_received: boolean;
  notify_refund_issued: boolean;
  notify_promoted_from_waitlist: boolean;
  notify_event_details_changed: boolean;
  created_at: string | null;
  updated_at: string | null;
}

/** Payload for PATCH /profile. payway_api_key is write-only — omit it to
 * leave the saved key untouched, or send "" (with merchant id also blank)
 * to disconnect PayWay entirely. */
export interface ProfileUpdatePayload {
  display_name?: string | null;
  avatar_url?: string | null;
  phone?: string | null;
  payway_merchant_id?: string;
  payway_api_key?: string;
  notify_payment_received?: boolean;
  notify_refund_issued?: boolean;
  notify_promoted_from_waitlist?: boolean;
  notify_event_details_changed?: boolean;
}

// ─── Auth ─────────────────────────────────────────────────────────────────────

export const authApi = {
  /**
   * `termsAccepted` is required, not optional — the backend rejects signup
   * with 422 code: "terms_not_accepted" unless it's `true` (see
   * event-freeze-and-terms-tickets.md's Ticket F). Making it a required
   * param here rather than optional-and-defaulted means a future call site
   * can't forget to wire up the checkbox and silently rely on the server's
   * rejection as the only guard.
   */
  async signup(
    email: string,
    password: string,
    termsAccepted: boolean,
    displayName?: string,
    recaptchaToken?: string,
  ) {
    const res = await api.post<{ token: string; user: ApiUser }>("/auth/signup", {
      email,
      password,
      terms_accepted: termsAccepted,
      display_name: displayName,
      recaptcha_token: recaptchaToken,
    });
    setToken(res.token);
    return res;
  },

  async signin(email: string, password: string) {
    const res = await api.post<{ token: string; user: ApiUser }>("/auth/signin", {
      email,
      password,
    });
    setToken(res.token);
    return res;
  },

  /** `impersonation` is present only during a staff support session. The
   *  banner is driven from here rather than from whatever the client stashed
   *  when the session opened, so a page refresh can't leave an admin browsing
   *  someone's account with nothing on screen saying so. */
  async me() {
    return api.get<{ user: ApiUser; impersonation?: ApiImpersonationState }>("/auth/me");
  },

  /** See ApiUser.terms_accepted_at's doc comment — the Google sign-in
   * counterpart to signup's terms checkbox. Idempotent server-side. */
  async acceptTerms() {
    return api.post<{ user: ApiUser }>("/auth/accept_terms");
  },

  /** idToken is the credential JWT from Google Identity Services' sign-in
   * button (see GoogleSignInButton) — verified server-side, never trusted
   * as-is here. */
  async google(idToken: string) {
    const res = await api.post<{ token: string; user: ApiUser }>("/auth/google", {
      id_token: idToken,
    });
    setToken(res.token);
    return res;
  },

  signout() {
    clearToken();
  },

  /** Logged-in password change — distinct from the forgot-password flow
   * (passwordResetsApi below), which needs no current password. Requires
   * the current one as proof, so a Google-only account that never set a
   * real password (see backend comment on AuthController#change_password)
   * will always fail here — the forgot-password flow is its escape hatch. */
  async changePassword(currentPassword: string, newPassword: string) {
    return api.patch<{ message: string }>("/auth/password", {
      current_password: currentPassword,
      new_password: newPassword,
      new_password_confirmation: newPassword,
    });
  },

  /** Changes the address immediately and drops email_verified back to
   * false, sending a fresh verification email to the new address. Requires
   * the current password — a bearer token alone shouldn't be enough to
   * redirect account-recovery email to a different address. */
  async changeEmail(currentPassword: string, newEmail: string) {
    return api.patch<{ user: ApiUser }>("/auth/email", {
      current_password: currentPassword,
      new_email: newEmail,
    });
  },

  /** Anonymizes the account (see backend User#discard!) — irreversible.
   * Rejected with `code: "has_paid_events"` if the user organizes an event
   * with a paid registration still outstanding; resolve those first. Clears
   * the local token on success since the account can no longer sign in. */
  async deleteAccount(currentPassword: string) {
    const res = await api.delete<{ message: string }>("/auth/account", {
      current_password: currentPassword,
    });
    clearToken();
    return res;
  },
};

// ─── Password resets ────────────────────────────────────────────────────────

export const passwordResetsApi = {
  request(email: string) {
    return api.post<{ message: string }>("/password_resets", { email });
  },

  reset(token: string, password: string, passwordConfirmation: string) {
    return api
      .patch<{ message: string; token: string }>(`/password_resets/${token}`, {
        password,
        password_confirmation: passwordConfirmation,
      })
      .then((res) => {
        setToken(res.token);
        return res;
      });
  },
};

// ─── Email verification ──────────────────────────────────────────────────────

export const emailVerificationsApi = {
  resend() {
    return api.post<{ message: string }>("/email_verifications");
  },

  confirm(token: string) {
    return api.get<{ message: string }>(`/email_verifications/${token}`);
  },
};

// ─── Events ───────────────────────────────────────────────────────────────────

/** The four purposes Rally refuses to host, plus an escape hatch.
 *
 * `other` exists because a fixed list always misses something, and a reporter
 * who can't find their category either picks the nearest wrong one — poisoning
 * the only signal a report carries — or gives up. */
export type EventReportReason = "political" | "gambling" | "violence" | "discrimination" | "other";

export const EVENT_REPORT_REASONS: EventReportReason[] = [
  "political",
  "gambling",
  "violence",
  "discrimination",
  "other",
];

export const eventsApi = {
  /**
   * Public event browsing. All options are optional — omitting them returns the
   * first page at the server's default page size, so callers that don't care
   * about paging can keep calling `list()` with no arguments.
   *
   * `category` must be one of EVENT_CATEGORY_VALUES; the backend returns 422
   * for anything else rather than silently returning nothing.
   */
  list(opts?: { q?: string; category?: string; page?: number; perPage?: number }) {
    const params = new URLSearchParams();
    if (opts?.q?.trim()) params.set("q", opts.q.trim());
    if (opts?.category) params.set("category", opts.category);
    if (opts?.page) params.set("page", String(opts.page));
    if (opts?.perPage) params.set("per_page", String(opts.perPage));

    const qs = params.toString();
    return api.get<{ events: ApiEvent[]; meta: ApiPageMeta }>(`/events${qs ? `?${qs}` : ""}`);
  },

  my() {
    return api.get<{ events: ApiEvent[] }>("/events/my");
  },

  get(id: string) {
    return api.get<{ event: ApiEvent }>(`/events/${id}`);
  },

  create(data: Partial<ApiEvent> & { event_types_attributes?: ApiEventTypeDraft[] }) {
    return api.post<{ event: ApiEvent }>("/events", { event: data });
  },

  update(
    id: string,
    data: Partial<ApiEvent> & {
      // Two shapes: a full draft (create/update an event type — `id` present
      // means update, absent means create) or a destroy-only entry (`{ id,
      // _destroy: true }`, nothing else) for removing an existing one. Kept
      // as a union rather than making every ApiEventTypeDraft field optional,
      // so a destroy entry can't accidentally be typo'd into a half-filled
      // update.
      event_types_attributes?: (
        (ApiEventTypeDraft & { id?: string }) | { id: string; _destroy: true }
      )[];
    },
  ) {
    return api.patch<{ event: ApiEvent }>(`/events/${id}`, { event: data });
  },

  delete(id: string) {
    return api.delete<{ message: string }>(`/events/${id}`);
  },

  /** Takes a published event down. Keeps its plan — republishing later is free. */
  unpublish(id: string) {
    return api.post<{ event: ApiEvent }>(`/events/${id}/unpublish`);
  },

  /**
   * Stops new sign-ups without hiding the event — deliberately not
   * `unpublish`, which takes the page away from people who already registered
   * and still need the date, the venue and later their results. Idempotent.
   */
  closeRegistration(id: string) {
    return api.post<{ event: ApiEvent }>(`/events/${id}/close_registration`);
  },

  /** Tell Rally staff to look at an event.
   *
   * Works signed in or not — the person best placed to report a gathering may
   * not want an account attached to it, so the server accepts anonymous
   * reports and rate-limits by IP instead.
   *
   * The response is identical whether this is the first report or the tenth,
   * and whether the event is already suspended: the endpoint deliberately
   * isn't an oracle for Rally's moderation state. Don't build UI that implies
   * otherwise. */
  report(id: string, reason: EventReportReason, details?: string) {
    return api.post<{ message: string }>(`/events/${id}/reports`, {
      report: { reason, details: details?.trim() || undefined },
    });
  },

  /** Clears the deadline as well as the manual close, so a passed deadline
   *  can't immediately re-close the event. */
  reopenRegistration(id: string) {
    return api.post<{ event: ApiEvent }>(`/events/${id}/reopen_registration`);
  },

  /** Organizer-only history of participant removals and price/date changes
   * on this event — see EventActivity on the backend. Deliberately narrower
   * than the staff-only admin audit log (Api::V1::Admin::AdminActionsController);
   * this only covers the organizer's own actions on their own event. */
  activity(id: string) {
    return api.get<{ activities: ApiEventActivity[] }>(`/events/${id}/activity`);
  },
};

/** One entry from eventsApi.activity(). `metadata`'s shape depends on
 * `action`: `remove_participant` carries `{ registration_id, participant_name,
 * participant_email }`; `update_event_details` carries one key per changed
 * field (currently only `price_cents`/`start_at`/`end_at`), each
 * `{ from, to }`; `invite_member`/`revoke_invitation` carry `{ email, role }`;
 * `member_joined` (the recipient accepting their own invite — actor IS the
 * member, so no name/email snapshot needed) carries `{ role }`;
 * `remove_member` carries `{ user_id, member_name, member_email,
 * self_removal }`; `change_member_role` carries `{ user_id, member_name,
 * member_email, from, to }`. */
export interface ApiEventActivity {
  id: string;
  action:
    | "remove_participant"
    | "update_event_details"
    | "invite_member"
    | "revoke_invitation"
    | "member_joined"
    | "remove_member"
    | "change_member_role";
  actor_name: string;
  metadata: Record<string, unknown>;
  created_at: string;
}

// ─── Event membership (team roles) ─────────────────────────────────────────
// See Api::V1::EventMembersController / EventInvitationsController on the
// backend. Listing (both members and invitations) is reachable by anyone on
// the team (see Api::V1::EventMembersController#index's own comment) —
// invite/revoke/role-change/remove are owner-only, enforced server-side via
// EventAuthorization::CAPABILITIES' :manage_members entry. This file exposes
// all of it; frontend/src/routes/_authenticated/dashboard_.events.$eventId.tsx
// decides what to actually render for the caller's role (Ticket G).

/** One row from eventMembersApi.list() — either a real EventMembership, or
 * the synthesized "owner" entry (id: null, since there's nothing to PATCH/
 * DELETE against — see EventMembersController#members_json). */
export interface ApiEventMember {
  id: string | null;
  user_id: string;
  role: "owner" | "manager" | "check_in" | "viewer";
  display_name: string | null;
  avatar_url: string | null;
  /** For the synthesized owner row, this is the event's own created_at
   * (creating the event *is* how the owner joined it). */
  joined_at: string;
}

export const eventMembersApi = {
  list(eventId: string) {
    return api.get<{ members: ApiEventMember[] }>(`/events/${eventId}/members`);
  },

  updateRole(eventId: string, membershipId: string, role: string) {
    return api.patch<{ member: ApiEventMember }>(`/events/${eventId}/members/${membershipId}`, {
      membership: { role },
    });
  },

  /** Removes a member, or leaves the team if `membershipId` is the caller's
   * own membership — same endpoint either way (see
   * EventMembersController#destroy's self_removal branch). */
  remove(eventId: string, membershipId: string) {
    return api.delete<{ message: string }>(`/events/${eventId}/members/${membershipId}`);
  },
};

/** One row from eventInvitationsApi.list() — a still-pending invite (the
 * endpoint only ever returns EventInvitation.pending rows, see
 * EventInvitationsController#index). */
export interface ApiEventInvitation {
  id: string;
  event_id: string;
  email: string;
  role: "manager" | "check_in" | "viewer";
  invited_by_id: string;
  expires_at: string;
  created_at: string;
}

export const eventInvitationsApi = {
  list(eventId: string) {
    return api.get<{ invitations: ApiEventInvitation[] }>(`/events/${eventId}/invitations`);
  },

  create(eventId: string, email: string, role: string) {
    return api.post<{ invitation: ApiEventInvitation }>(`/events/${eventId}/invitations`, {
      email,
      role,
    });
  },

  revoke(eventId: string, invitationId: string) {
    return api.delete<{ message: string }>(`/events/${eventId}/invitations/${invitationId}`);
  },
};

// ─── Pricing plans ──────────────────────────────────────────────────────────

export interface ApiEventPlan {
  id: string;
  label: string;
  capacity: number;
  price_cents: number;
}

export const eventPlansApi = {
  list() {
    return api.get<{ plans: ApiEventPlan[] }>("/event_plans");
  },
};

// ─── Registrations ────────────────────────────────────────────────────────────

export const registrationsApi = {
  mine() {
    return api.get<{ registrations: ApiRegistration[] }>("/registrations");
  },

  /**
   * Organizer-only, **paginated**. Returns one page of participants plus
   * `meta` — it used to return every registration, which is what made the
   * manage page load thousands of rows just to render a stat card.
   *
   * For public capacity display use the event's own `registrations_count`
   * (from eventsApi.get, no auth); for totals and revenue use `summary()`
   * below, never the length of this array.
   */
  forEvent(eventId: string, params: { page?: number; perPage?: number; q?: string } = {}) {
    const qs = new URLSearchParams();
    if (params.page) qs.set("page", String(params.page));
    if (params.perPage) qs.set("per_page", String(params.perPage));
    // Only sent when non-empty: a blank q is "no filter", and omitting it
    // keeps the URL (and so the react-query cache key) stable.
    if (params.q?.trim()) qs.set("q", params.q.trim());
    const suffix = qs.toString() ? `?${qs}` : "";

    return api.get<{ registrations: ApiRegistration[]; meta: ApiPageMeta }>(
      `/events/${eventId}/registrations${suffix}`,
    );
  },

  /**
   * Aggregate figures computed in SQL. The stat cards read these rather than
   * summing a page of the list — a paginated list can't answer "how much
   * revenue" without under-reporting it.
   */
  summary(eventId: string) {
    return api.get<{ summary: ApiRegistrationSummary }>(`/events/${eventId}/registrations/summary`);
  },

  /** Downloads the participant list as a CSV (name, email, event type(s),
   * payment/check-in status, plus one column per survey question) for
   * offline use — check-in sheets, mail merges. Organizer-only, same
   * authorization as forEvent(). Triggers a browser file download rather
   * than returning parsed data. */
  exportCsv(eventId: string) {
    return downloadFile(`/events/${eventId}/registrations/export`, `registrations-${eventId}.csv`);
  },

  /** `guest` is only needed when the visitor isn't signed in (see
   * useAuth()'s `user`) — the backend requires a name plus at least one of
   * email/phone (phone is Cambodia's most common contact channel, so it's
   * a first-class alternative to email, not a fallback).
   *
   * Guest checkout never signs the visitor in — not even when the contact
   * info matches an existing account (it's silently attached to that
   * account instead; see Registrations::GuestCheckout on the backend). No
   * token comes back here. Hang on to the same `guest` contact info the
   * caller passed in and pass it again to paymentsApi.create/status,
   * which authorize a guest's payment by matching contact info instead of
   * a session. */
  create(
    eventId: string,
    opts?: {
      answers?: ApiRegistrationAnswer[];
      eventTypeIds?: string[];
      guest?: { name: string; email?: string; phone?: string };
    },
  ) {
    return api.post<{ registration: ApiRegistration }>(`/events/${eventId}/registrations`, {
      answers: opts?.answers ?? [],
      event_type_ids: opts?.eventTypeIds ?? [],
      guest: opts?.guest,
    });
  },

  myRegistrationForEvent(eventId: string) {
    return api
      .get<{ registrations: ApiRegistration[] }>("/registrations")
      .then((r) => r.registrations.find((reg) => reg.event_id === eventId) ?? null);
  },

  updatePayment(id: string, paymentStatus: string, amountPaidCents: number) {
    return api.patch<{ registration: ApiRegistration }>(`/registrations/${id}`, {
      registration: { payment_status: paymentStatus, amount_paid_cents: amountPaidCents },
    });
  },

  /** Assigns or clears a race number. Pass null to clear — the backend
   * normalizes null and "" to NULL so the row stops counting against the
   * per-event uniqueness index. A duplicate comes back as a 422 whose
   * message names the conflict; there's no pre-check, because between a
   * check and a write another organizer could take the number. */
  setBibNumber(id: string, bibNumber: string | null) {
    return api.patch<{ registration: ApiRegistration }>(`/registrations/${id}`, {
      registration: { bib_number: bibNumber?.trim() || null },
    });
  },

  remove(id: string) {
    return api.delete<{ message: string }>(`/registrations/${id}`);
  },

  /** Organizer scans the attendee's ticket QR (which just encodes this id)
   * or taps them in from the manual list. Idempotent — re-checking-in an
   * already-checked-in registration succeeds and reports
   * `already_checked_in: true` rather than erroring. */
  checkIn(id: string) {
    return api.post<{ registration: ApiRegistration; already_checked_in: boolean }>(
      `/registrations/${id}/check_in`,
    );
  },

  /** Undoes a mis-scan/mis-tap. */
  undoCheckIn(id: string) {
    return api.delete<{ registration: ApiRegistration }>(`/registrations/${id}/check_in`);
  },

  /** Sets (or, with `null`, clears) one participant's finish time. */
  setResult(id: string, finishTimeSeconds: number | null) {
    return api.patch<{
      result: { id: string; registration_id: string; finish_time_seconds: number | null };
    }>(`/registrations/${id}/result`, { result: { finish_time_seconds: finishTimeSeconds } });
  },
};

// ─── Results (finish times) ────────────────────────────────────────────────────

export interface ApiResultsImportSummary {
  updated: number;
  /** `bib` and `email` echo whichever key the failing row actually used, so
   * the list reads against the file that was uploaded. A timing export has
   * only bibs and a hand-made sheet often has only emails, so either can be
   * null — display code should fall back from one to the other. */
  errors: Array<{ row: number; bib: string | null; email: string | null; reason: string }>;
}

export interface ApiLeaderboardEntry {
  placement: number;
  registration_id: string;
  user_id: string;
  display_name: string | null;
  finish_time_seconds: number;
}

export interface ApiLeaderboardGroup {
  /** Null when the event has no event types — one combined group. */
  event_type_id: string | null;
  event_type_name: string | null;
  /** Ranked ascending by finish time; empty until an organizer records at
   * least one result for this group (e.g. every non-race "gathering"
   * event, by design — see Result's backend class comment). */
  results: ApiLeaderboardEntry[];
}

export const resultsApi = {
  /** CSV columns: email,finish_time — finish_time accepts "H:MM:SS",
   * "MM:SS", or a bare number of seconds. */
  async importCsv(eventId: string, file: File): Promise<ApiResultsImportSummary> {
    const form = new FormData();
    form.append("file", file);
    return api.upload<ApiResultsImportSummary>(`/events/${eventId}/results/import`, form);
  },

  /** Public — no auth required. Returns one group per event type (or a
   * single combined group when the event has none), each independently
   * ranked. */
  leaderboard(eventId: string) {
    return api.get<{ groups: ApiLeaderboardGroup[] }>(`/events/${eventId}/results`);
  },
};

// ─── Waitlists ──────────────────────────────────────────────────────────────

export const waitlistApi = {
  /** Current user's own active (still-waiting) waitlist spots, across all events. */
  mine() {
    return api.get<{ waitlist_entries: ApiWaitlistEntry[] }>("/waitlist_entries");
  },

  myEntryForEvent(eventId: string) {
    return waitlistApi
      .mine()
      .then((r) => r.waitlist_entries.find((e) => e.event_id === eventId) ?? null);
  },

  join(eventId: string, opts?: { eventTypeIds?: string[] }) {
    return api.post<{ waitlist_entry: ApiWaitlistEntry }>(`/events/${eventId}/waitlist_entries`, {
      event_type_ids: opts?.eventTypeIds ?? [],
    });
  },

  /** Organizer-only — the full queue for one of *their* events, in join order. */
  forEvent(eventId: string) {
    return api.get<{ waitlist_entries: ApiWaitlistEntry[] }>(`/events/${eventId}/waitlist_entries`);
  },

  leave(id: string) {
    return api.delete<{ message: string }>(`/waitlist_entries/${id}`);
  },
};

// ─── Profile ──────────────────────────────────────────────────────────────────

export const profileApi = {
  get() {
    return api.get<{ profile: ApiProfile }>("/profile");
  },

  update(data: ProfileUpdatePayload) {
    return api.patch<{ profile: ApiProfile }>("/profile", { profile: data });
  },
};

// ─── Organizations ────────────────────────────────────────────────────────────
//
// The identity an event is presented under — see
// organization-identity-tickets.md. A user may own or administer several, so
// nothing here infers "the current organization"; the caller always names one.
//
// Distinct from `organizerApi` below, which is the world-readable public page.
// These endpoints require a relationship with the organization and return
// things a public page must never carry (payment status, owner identity).

export type OrganizationRole = "owner" | "admin" | "member";

export interface ApiOrganization {
  id: string;
  /** Immutable once generated — renaming changes `name`, never this, so
   * links an organizer already shared keep working. */
  slug: string;
  name: string;
  description: string | null;
  logo_url: string | null;
  banner_url: string | null;
  brand_color: string | null;
  website: string | null;
  /** The address the organizer publishes, not the one they sign in with. */
  contact_email: string | null;
  contact_phone: string | null;
  facebook_url: string | null;
  instagram_url: string | null;
  telegram_url: string | null;
  verified: boolean;
  suspended: boolean;
  owner_id: string;
  /** What the caller may do here — the server's answer, so the UI doesn't
   * re-derive the rules and drift from it. */
  role: OrganizationRole | null;
  /** Publish-readiness. `missing_identity_fields` names what's still needed;
   * `identity_required` says whether the gate is currently enforced (see the
   * backend's REQUIRE_ORGANIZATION_IDENTITY). */
  identity_complete: boolean;
  missing_identity_fields: string[];
  identity_required: boolean;
  /** Never the plaintext key — see payway_api_key_masked. Both identifiers
   *  come back null in a staff support session; `payway_hidden` is how you
   *  tell that apart from "nothing saved yet", which is a different fact and
   *  a different empty state. */
  payway_merchant_id: string | null;
  payway_api_key_masked: string | null;
  /** True only during a staff support session (see the impersonation design).
   *  The booleans below stay truthful either way — whether a credential exists
   *  is not the credential. */
  payway_hidden: boolean;
  payway_configured: boolean;
  payway_refund_configured: boolean;
  events_count: number;
  created_at: string;
  updated_at: string;
}

export interface ApiOrganizationMember {
  /** null for the owner — they're a column on the organization, not a
   * membership row, so there's nothing to PATCH or DELETE against. */
  id: string | null;
  user_id: string;
  role: OrganizationRole;
  email: string;
  display_name: string | null;
  avatar_url: string | null;
  joined_at: string;
}

export interface OrganizationPayload {
  name?: string;
  description?: string | null;
  logo_url?: string | null;
  banner_url?: string | null;
  brand_color?: string | null;
  website?: string | null;
  contact_email?: string | null;
  contact_phone?: string | null;
  facebook_url?: string | null;
  instagram_url?: string | null;
  telegram_url?: string | null;
  /** Owner-only — an admin sending these gets 403, deliberately, rather than
   * having them silently dropped. */
  payway_merchant_id?: string;
  payway_api_key?: string;
  payway_rsa_public_key?: string;
}

export const organizationsApi = {
  /** Everything the caller owns or administers — the org switcher's source.
   * Plain memberships are excluded: they grant no authority. */
  list() {
    return api.get<{ organizations: ApiOrganization[] }>("/organizations");
  },

  get(slug: string) {
    return api.get<{ organization: ApiOrganization }>(`/organizations/${slug}`);
  },

  create(data: OrganizationPayload) {
    return api.post<{ organization: ApiOrganization }>("/organizations", { organization: data });
  },

  update(slug: string, data: OrganizationPayload) {
    return api.patch<{ organization: ApiOrganization }>(`/organizations/${slug}`, {
      organization: data,
    });
  },

  /** Soft-delete. Refused while the organization still presents events. */
  remove(slug: string) {
    return api.delete<{ message: string }>(`/organizations/${slug}`);
  },

  /** Owner-only, and only to an existing admin. The outgoing owner stays on
   * as an admin. */
  transferOwnership(slug: string, userId: string) {
    return api.post<{ organization: ApiOrganization }>(
      `/organizations/${slug}/transfer_ownership`,
      { user_id: userId },
    );
  },

  members(slug: string) {
    return api.get<{ members: ApiOrganizationMember[] }>(`/organizations/${slug}/members`);
  },

  /** Adds someone who already has a Rally account — there's no invitation
   * flow for organizations yet, so an unknown email is rejected. */
  addMember(slug: string, email: string, role: OrganizationRole) {
    return api.post<{ member: ApiOrganizationMember }>(`/organizations/${slug}/members`, {
      member: { email, role },
    });
  },

  updateMember(slug: string, id: string, role: OrganizationRole) {
    return api.patch<{ member: ApiOrganizationMember }>(`/organizations/${slug}/members/${id}`, {
      membership: { role },
    });
  },

  removeMember(slug: string, id: string) {
    return api.delete<{ message: string }>(`/organizations/${slug}/members/${id}`);
  },
};

// ─── Public organizer page ────────────────────────────────────────────────────
//
// World-readable, no auth. Deliberately a separate resource from
// organizationsApi above: two payloads with opposite audiences, so they share
// no type and no endpoint.

export interface ApiOrganizerEvent {
  id: string;
  title: string;
  category: string;
  location: string | null;
  start_at: string;
  end_at: string | null;
  price_cents: number;
  currency: string;
  banner_url: string | null;
  logo_url: string | null;
  brand_color: string | null;
}

export interface ApiOrganizer {
  slug: string;
  name: string;
  description: string | null;
  logo_url: string | null;
  banner_url: string | null;
  brand_color: string | null;
  website: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  facebook_url: string | null;
  instagram_url: string | null;
  telegram_url: string | null;
  verified: boolean;
  /** Trust signals. `events_run` counts finished events only — an organizer
   * with fifty upcoming and none delivered has no track record yet. */
  member_since: string;
  events_run: number;
  participants_hosted: number;
  upcoming_events: ApiOrganizerEvent[];
  past_events: ApiOrganizerEvent[];
}

export const organizerApi = {
  get(slug: string) {
    return api.get<{ organizer: ApiOrganizer }>(`/organizers/${slug}`);
  },
};

// ─── Uploads ──────────────────────────────────────────────────────────────────

/**
 * What Certificates::InspectTemplate found in an uploaded .odt.
 *
 * `split` is the one that matters: those tokens exist in the document but are
 * broken across formatting runs, so MergeOdt's literal substitution won't
 * match them and the braces will print on every certificate. `missing` is
 * informational — an organizer may simply not want that field.
 */
export interface CertificateTemplateCheck {
  valid_odt: boolean;
  usable: boolean;
  present: string[];
  split: string[];
  missing: string[];
}

export interface CertificateTemplateUploadResult {
  url: string;
  signed_id: string;
  template_check: CertificateTemplateCheck;
}

export const uploadsApi = {
  async upload(file: File, type: "banner" | "logo" | "avatar"): Promise<string> {
    const form = new FormData();
    form.append("file", file);
    form.append("type", type);
    const res = await api.upload<{ url: string }>("/uploads", form);
    return res.url;
  },

  /**
   * Separate from `upload` because this is the only upload type whose response
   * carries more than a URL, and folding the richer shape into the shared
   * method would make every image call site pretend to care about it.
   */
  async uploadCertificateTemplate(file: File): Promise<CertificateTemplateUploadResult> {
    const form = new FormData();
    form.append("file", file);
    form.append("type", "certificate_template");
    return api.upload<CertificateTemplateUploadResult>("/uploads", form);
  },
};

// ─── Certificate preview ──────────────────────────────────────────────────────

export type CertificatePreviewStatus = "pending" | "ready" | "failed";

export interface CertificatePreview {
  status: CertificatePreviewStatus;
  file_url: string | null;
  error_code: string | null;
  updated_at: string;
}

export const certificatePreviewApi = {
  /**
   * Enqueues a render and returns immediately with `pending` — the conversion
   * runs on the job worker (LibreOffice, ~1-4s and ~180 MB), never in the
   * request.
   *
   * `signedId` is optional. Pass it right after an upload, to preview a
   * template that isn't saved yet; omit it to preview whatever is already
   * saved on the event, which is the case on every later visit once the page
   * has been reloaded. Never a URL in either direction — an endpoint that
   * accepted one and fetched it would be an SSRF hole.
   */
  async request(
    eventId: string,
    signedId?: string | null,
  ): Promise<{ preview: CertificatePreview }> {
    return api.post<{ preview: CertificatePreview }>(
      `/events/${eventId}/certificate_preview`,
      signedId ? { signed_id: signedId } : {},
    );
  },

  /** Poll target. Resolves `{ preview: null }` when none has been requested. */
  async get(eventId: string): Promise<{ preview: CertificatePreview | null }> {
    return api.get<{ preview: CertificatePreview | null }>(
      `/events/${eventId}/certificate_preview`,
    );
  },
};

// ─── Surveys ──────────────────────────────────────────────────────────────────

export interface SurveyQuestionDraft {
  question_text: string;
  question_type: SurveyQuestionType;
  options: ApiSurveyOption[];
  required: boolean;
}

export const surveysApi = {
  list() {
    return api.get<{ surveys: ApiSurvey[] }>("/surveys");
  },

  get(id: string) {
    return api.get<{ survey: ApiSurvey }>(`/surveys/${id}`);
  },

  create(title: string, questions: SurveyQuestionDraft[]) {
    return api.post<{ survey: ApiSurvey }>("/surveys", { title, questions });
  },

  update(id: string, title: string, questions: SurveyQuestionDraft[]) {
    return api.patch<{ survey: ApiSurvey }>(`/surveys/${id}`, { title, questions });
  },

  delete(id: string) {
    return api.delete<{ message: string }>(`/surveys/${id}`);
  },
};

// ─── Survey Responses ─────────────────────────────────────────────────────────

export interface ApiSurveyResponse {
  registration_id: string;
  user: { id: string; display_name: string | null; email: string };
  answers: Array<{
    survey_question_id: string;
    question_text: string;
    question_type: SurveyQuestionType;
    answer_text: string | null;
    answer_options: string[];
  }>;
}

export const surveyResponsesApi = {
  forEvent(eventId: string) {
    return api.get<{ survey: ApiSurvey; responses: ApiSurveyResponse[] }>(
      `/events/${eventId}/survey_responses`,
    );
  },
};

// ─── Payments (ABA PayWay KHQR) ────────────────────────────────────────────────

export type PaymentStatus =
  "pending" | "approved" | "declined" | "cancelled" | "expired" | "refunded";

export interface ApiPayment {
  id: string;
  registration_id: string;
  status: PaymentStatus;
  amount_cents: number;
  currency: string;
  qr_string: string | null;
  abapay_deeplink: string | null;
  expires_at: string | null;
  paid_at: string | null;
  created_at: string;
}

/** Only needed when there's no signed-in session — guest checkout never
 * signs anyone in (see registrationsApi.create). The backend authorizes
 * the request by matching this against the registration's own account
 * instead of a login; either field alone is enough if it matches. */
export interface GuestContact {
  email?: string;
  phone?: string;
}

function guestContactQuery(guestContact?: GuestContact): string {
  if (!guestContact) return "";
  const params = new URLSearchParams();
  if (guestContact.email) params.set("email", guestContact.email);
  if (guestContact.phone) params.set("phone", guestContact.phone);
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

export const paymentsApi = {
  create(registrationId: string, guestContact?: GuestContact) {
    return api.post<{ payment: ApiPayment }>(`/registrations/${registrationId}/payments`, {
      email: guestContact?.email,
      phone: guestContact?.phone,
    });
  },

  status(paymentId: string, guestContact?: GuestContact) {
    return api.get<{ payment: ApiPayment }>(
      `/payments/${paymentId}${guestContactQuery(guestContact)}`,
    );
  },
};

// ─── Event plan payments (organizer pays to publish) ───────────────────────

export type PlanPaymentStatus = "pending" | "paid" | "declined" | "cancelled" | "expired";

export interface ApiEventPlanPayment {
  id: string;
  event_id: string;
  plan: string;
  status: PlanPaymentStatus;
  amount_cents: number;
  currency: string;
  qr_string: string | null;
  abapay_deeplink: string | null;
  expires_at: string | null;
  paid_at: string | null;
  created_at: string;
}

export const eventPlanPaymentsApi = {
  /** Starts (or, for the free tier / a re-pick of the same plan, completes) publishing. */
  create(eventId: string, plan: string) {
    return api.post<{ plan_payment?: ApiEventPlanPayment; event?: ApiEvent }>(
      `/events/${eventId}/plan_payments`,
      { plan },
    );
  },

  status(planPaymentId: string) {
    return api.get<{ plan_payment: ApiEventPlanPayment; event: ApiEvent }>(
      `/plan_payments/${planPaymentId}`,
    );
  },
};

// ─── Admin / moderation ───────────────────────────────────────────────────────

export interface ApiAdminUser {
  id: string;
  email: string;
  display_name: string | null;
  email_verified: boolean;
  /** Admin-granted organizer verification — unrelated to email_verified
   * above. Gates creating paid events. See User#verified? server-side. */
  verified: boolean;
  verified_at: string | null;
  admin: boolean;
  suspended: boolean;
  suspended_at: string | null;
  suspension_reason: string | null;
  provider: string | null;
  /** Only populated by the index endpoint, which selects it. */
  events_count: number | null;
  created_at: string;
}

export interface ApiAdminEvent {
  id: string;
  title: string;
  category: string;
  location: string | null;
  start_at: string;
  is_published: boolean;
  /** Admin-only-reversible moderation lock — see ApiEvent.suspended's comment. */
  suspended: boolean;
  suspension_reason: string | null;
  suspended_at: string | null;
  plan: string | null;
  capacity: number | null;
  price_cents: number;
  currency: string;
  registrations_count: number;
  creator: {
    id: string;
    email: string;
    display_name: string | null;
    suspended: boolean;
  };
  created_at: string;
}

export type ApiReportPeriod = "week" | "month" | "year";

export interface ApiAdminTotals {
  events_count: number;
  published_events_count: number;
  users_count: number;
  registrations_count: number;
  /** Always USD — what organizers pay Rally to publish an event (see
   * EventPlanPayment). This is Rally's own revenue. */
  platform_revenue_cents: number;
  /** Attendee registration payments — money that flows to organizers, not
   * Rally. Broken out by currency since an event's currency is
   * organizer-settable (defaults to "usd" but isn't locked to it). */
  registration_volume: Array<{ currency: string; amount_cents: number }>;
}

export interface ApiAdminTopEvent {
  id: string;
  title: string;
  category: string;
  start_at: string;
  registrations_count: number;
}

export interface ApiAdminReports {
  totals: ApiAdminTotals;
  /** One point per bucket for the requested period, oldest first, with
   * empty buckets zero-filled — safe to feed straight into a chart. */
  events_by_period: Array<{ period: string; count: number }>;
  platform_revenue_by_period: Array<{ period: string; amount_cents: number }>;
  top_events: ApiAdminTopEvent[];
}

/**
 * Rally staff moderation endpoints. Every call requires an admin account;
 * non-admins get a 404 (not a 403) so the surface isn't discoverable, which
 * surfaces here as an ApiError with "Not found".
 */
export const adminApi = {
  reports(period: ApiReportPeriod = "month") {
    return api.get<ApiAdminReports>(`/admin/reports?period=${period}`);
  },

  users(opts?: {
    q?: string;
    status?: "all" | "active" | "suspended";
    page?: number;
    perPage?: number;
  }) {
    const params = new URLSearchParams();
    if (opts?.q?.trim()) params.set("q", opts.q.trim());
    if (opts?.status && opts.status !== "all") params.set("status", opts.status);
    if (opts?.page) params.set("page", String(opts.page));
    if (opts?.perPage) params.set("per_page", String(opts.perPage));

    const qs = params.toString();
    return api.get<{ users: ApiAdminUser[]; meta: ApiPageMeta }>(
      `/admin/users${qs ? `?${qs}` : ""}`,
    );
  },

  /** Also unpublishes every event the user created — see User#suspend!. */
  suspendUser(id: string, reason?: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/suspend`, { reason });
  },

  /** Does NOT re-publish events the suspension took down. */
  unsuspendUser(id: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/unsuspend`);
  },

  /** Unlocks creating paid events for this organizer — see User#verified?. */
  verifyUser(id: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/verify`);
  },

  /** Forward-looking only — the organizer's existing paid events stay live. */
  unverifyUser(id: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/unverify`);
  },

  events(opts?: {
    q?: string;
    status?: "all" | "published" | "draft";
    category?: string;
    page?: number;
    perPage?: number;
  }) {
    const params = new URLSearchParams();
    if (opts?.q?.trim()) params.set("q", opts.q.trim());
    if (opts?.status && opts.status !== "all") params.set("status", opts.status);
    if (opts?.category) params.set("category", opts.category);
    if (opts?.page) params.set("page", String(opts.page));
    if (opts?.perPage) params.set("per_page", String(opts.perPage));

    const qs = params.toString();
    return api.get<{ events: ApiAdminEvent[]; meta: ApiPageMeta }>(
      `/admin/events${qs ? `?${qs}` : ""}`,
    );
  },

  /** Reversible: leaves registrations and the paid plan intact. */
  unpublishEvent(id: string) {
    return api.post<{ event: ApiAdminEvent }>(`/admin/events/${id}/unpublish`);
  },

  /**
   * Stronger than unpublishEvent — NOT reversible by the organizer at all
   * (see EventAuthorization's suspended lockdown). `reason` is required by the
   * API and is emailed to the owner verbatim, so it's a real argument here,
   * not optional like suspendUser's.
   */
  suspendEvent(id: string, reason: string) {
    return api.post<{ event: ApiAdminEvent }>(`/admin/events/${id}/suspend`, { reason });
  },

  /** Does NOT re-publish the event — that stays the owner's own decision. */
  unsuspendEvent(id: string) {
    return api.post<{ event: ApiAdminEvent }>(`/admin/events/${id}/unsuspend`);
  },

  /**
   * Irreversible, and rejected server-side if the event has paid
   * registrations. `confirm` is required by the API — passed explicitly rather
   * than defaulted so a stray call can't delete anything.
   */
  deleteEvent(id: string) {
    return api.delete<{ message: string }>(`/admin/events/${id}?confirm=true`);
  },
};

/**
 * Web push subscriptions.
 *
 * The VAPID public key is fetched at runtime rather than compiled in as a
 * `VITE_` var on purpose: this app is built once and cached on CloudFront, so
 * a baked-in key could only change with a rebuild plus an invalidation, and
 * would silently disagree with the backend in between. `enabled: false` means
 * the server has no keypair configured — hide the feature rather than prompt
 * for a permission nothing can act on.
 */
export const pushApi = {
  vapidPublicKey() {
    return api.get<{ enabled: boolean; public_key: string | null }>("/push/vapid_public_key");
  },

  /** Flattened from the browser's PushSubscription so the wire format is ours. */
  subscribe(sub: { endpoint: string; p256dhKey: string; authKey: string }) {
    return api.post<{ subscription: { id: string; endpoint: string } }>("/push/subscriptions", {
      subscription: {
        endpoint: sub.endpoint,
        p256dh_key: sub.p256dhKey,
        auth_key: sub.authKey,
      },
    });
  },

  /**
   * A POST, not a DELETE. The endpoint belongs in a body — it's a long opaque
   * URL, and a query string would put a specific device's address into every
   * access log — but bodies on DELETE aren't reliably parsed end to end
   * (Rails, and any proxy in between). POST removes the ambiguity.
   *
   * Returns 204 whether or not the subscription existed.
   */
  unsubscribe(endpoint: string) {
    return api.post<void>("/push/unsubscribe", { endpoint });
  },
};

/** One in-app notification — what the header bell lists. */
export interface ApiNotification {
  id: string;
  kind: string;
  title: string;
  body: string | null;
  url: string | null;
  event_id: string | null;
  read: boolean;
  created_at: string;
}

export const notificationsApi = {
  /**
   * Polled roughly once a minute by open tabs, and refetched immediately when
   * the service worker reports a push (see usePushNotificationSignal).
   *
   * `unread_count` is capped at `max_count` server-side — render it as
   * "{max_count}+" when it exceeds, rather than showing an exact number nobody
   * acts on differently.
   */
  list() {
    return api.get<{
      notifications: ApiNotification[];
      unread_count: number;
      max_count: number;
    }>("/notifications");
  },

  markRead(id: string) {
    return api.post<{ notification: ApiNotification; unread_count: number }>(
      `/notifications/${id}/read`,
    );
  },

  markAllRead() {
    return api.post<{ unread_count: number }>("/notifications/read_all");
  },
};

// ─── Support chat ─────────────────────────────────────────────────────────────

/**
 * One message in the participant's support thread.
 *
 * Shape mirrors `Support::Serializers.participant_message` exactly — the same
 * payload arrives over REST and over the WebSocket, and the UI merges both into
 * one list, so any drift would surface as messages rendering differently
 * depending on how they arrived.
 *
 * Note there is no sender name: a participant needs to know which *side* spoke,
 * not which employee, so staff messages render from `sender_role` alone.
 */
export interface ApiSupportMessage {
  id: string;
  body: string;
  sender_role: "participant" | "staff" | "system";
  created_at: string;
}

/** Mirrors `Support::Serializers.participant_conversation`. */
export interface ApiSupportConversation {
  id: string;
  status: "open" | "pending" | "resolved";
  subject: string | null;
  unread_count: number;
  last_message_at: string | null;
  created_at: string;
}

export const supportApi = {
  /**
   * The caller's live thread, or `null` — which is the normal state for almost
   * everyone, hence null rather than a 404. Polled by the launcher for its
   * unread badge.
   */
  conversation() {
    return api.get<{ conversation: ApiSupportConversation | null }>("/support/conversation");
  },

  /**
   * Idempotent: returns the existing live thread if there is one. Not required
   * before sending — `sendMessage` starts a thread on its own — but useful to
   * pre-create one when the panel opens.
   */
  startConversation(subject?: string) {
    return api.post<{ conversation: ApiSupportConversation }>(
      "/support/conversation",
      subject ? { subject } : undefined,
    );
  },

  /**
   * Three modes, and `has_more` answers the question belonging to each:
   *   (none)   newest page, oldest-first. has_more => older history above.
   *   after    everything since a known message — the reconnect catch-up.
   *   before   scrolling back through history.
   * `after` wins if both are given.
   */
  messages(params: { after?: string; before?: string } = {}) {
    const query = new URLSearchParams();
    if (params.after) query.set("after", params.after);
    else if (params.before) query.set("before", params.before);
    const suffix = query.toString() ? `?${query}` : "";

    return api.get<{
      conversation: ApiSupportConversation | null;
      messages: ApiSupportMessage[];
      has_more: boolean;
    }>(`/support/messages${suffix}`);
  },

  sendMessage(body: string) {
    return api.post<{ message: ApiSupportMessage; conversation: ApiSupportConversation }>(
      "/support/messages",
      { body },
    );
  },

  markRead() {
    return api.post<{ conversation: ApiSupportConversation | null }>("/support/read");
  },
};

export const cableApi = {
  /**
   * A single-use, 30-second credential for opening the WebSocket.
   *
   * Browsers can't set headers on a WebSocket, and this app's JWT lasts 30
   * days — far too long to put in a URL that lands in access logs and browser
   * history. Every connection attempt needs its own ticket; they cannot be
   * cached or reused.
   */
  ticket() {
    return api.post<{ ticket: string; expires_in: number }>("/cable/ticket");
  },
};

/**
 * The `wss://` endpoint for a given ticket. Built here because this module owns
 * the API origin, and getting it wrong is invisible until the socket silently
 * fails to connect.
 */
export function cableUrl(ticket: string): string {
  return `${RAW_API_URL.replace(/^http/, "ws")}/cable?ticket=${encodeURIComponent(ticket)}`;
}

// ─── Admin: support chat ──────────────────────────────────────────────────────

/** Mirrors `Support::Serializers.staff_conversation`. Unlike the participant
 *  shape this names the participant and carries the assignment. */
export interface ApiAdminConversation {
  id: string;
  status: "open" | "pending" | "resolved";
  subject: string | null;
  unread: boolean;
  assigned_admin_id: string | null;
  last_message_at: string | null;
  created_at: string;
  participant: { id: string; display_name: string | null; email: string };
}

export interface ApiAdminConversationDetail extends ApiAdminConversation {
  staff_last_read_at: string | null;
  participant_last_read_at: string | null;
}

/** Mirrors `Support::Serializers.staff_message` — names the colleague who
 *  replied, which the participant-facing shape deliberately does not. */
export interface ApiAdminSupportMessage {
  id: string;
  body: string;
  sender_role: "participant" | "staff" | "system";
  sender_id: string | null;
  sender_name: string | null;
  created_at: string;
}

/** The context that justifies building this rather than embedding a widget:
 *  what this person actually registered for, and whether they paid. */
export interface ApiSupportParticipant {
  id: string;
  email: string;
  display_name: string | null;
  suspended: boolean;
  created_at: string;
  registrations: Array<{
    id: string;
    event_title: string | null;
    status: string;
    payment_status: string;
    amount_paid_cents: number;
    refunded_cents: number;
    created_at: string;
  }>;
}

export const adminSupportApi = {
  /**
   * `awaiting_count` is counted independently of the current filter — it means
   * "how much is waiting on us", not "how many rows are on this screen".
   */
  conversations(opts?: {
    status?: "all" | "live" | "open" | "pending" | "resolved";
    assignment?: "any" | "mine" | "unassigned";
    unread?: boolean;
    page?: number;
    perPage?: number;
  }) {
    const query = new URLSearchParams();
    if (opts?.status) query.set("status", opts.status);
    if (opts?.assignment) query.set("assignment", opts.assignment);
    if (opts?.unread) query.set("unread", "true");
    if (opts?.page) query.set("page", String(opts.page));
    if (opts?.perPage) query.set("per_page", String(opts.perPage));
    const suffix = query.toString() ? `?${query}` : "";

    return api.get<{
      conversations: ApiAdminConversation[];
      meta: { page: number; per_page: number; total_count: number; total_pages: number };
      awaiting_count: number;
    }>(`/admin/conversations${suffix}`);
  },

  conversation(id: string) {
    return api.get<{
      conversation: ApiAdminConversationDetail;
      participant: ApiSupportParticipant;
      messages: ApiAdminSupportMessage[];
    }>(`/admin/conversations/${id}`);
  },

  reply(id: string, body: string) {
    return api.post<{
      message: ApiAdminSupportMessage;
      conversation: ApiAdminConversationDetail;
    }>(`/admin/conversations/${id}/messages`, { body });
  },

  /** A soft claim, self-only. Refused on a resolved thread — there's no work
   *  left to claim — while `unassign` is allowed, so a stale claim on a thread
   *  resolved out from under it can still be cleared. */
  assign(id: string) {
    return api.post<{ conversation: ApiAdminConversationDetail }>(
      `/admin/conversations/${id}/assign`,
    );
  },

  unassign(id: string) {
    return api.post<{ conversation: ApiAdminConversationDetail }>(
      `/admin/conversations/${id}/unassign`,
    );
  },

  resolve(id: string) {
    return api.post<{ conversation: ApiAdminConversationDetail }>(
      `/admin/conversations/${id}/resolve`,
    );
  },

  markRead(id: string) {
    return api.post<{ conversation: ApiAdminConversationDetail }>(
      `/admin/conversations/${id}/read`,
    );
  },
};

export type EventReportStatus = "open" | "reviewing" | "actioned" | "dismissed";

/** Queue priority only. It orders the reviewer's day and never hides anything
 *  on its own — see `AdminEventReports` for why auto-action is refused. */
export type EventReportPriority = "urgent" | "high" | "normal";

export interface ApiReportedEventSummary {
  id: string;
  title: string;
  description: string | null;
  category: string | null;
  location: string | null;
  start_at: string | null;
  is_published: boolean;
  visibility: "public" | "unlisted";
  suspended: boolean;
  suspension_reason: string | null;
  organization: { slug: string; name: string } | null;
}

/** One row of the queue: an event, not a report. Twelve reports on one event
 *  are one decision. */
export interface ApiEventReportGroup {
  event: ApiReportedEventSummary;
  /** Reports matching the active filter — why this row is in this list. */
  report_count: number;
  /** Every live report on the event, *ignoring* the filter: it answers "is
   *  there work left here", which is a fact about the event rather than about
   *  the current view. `priority` is derived from it for the same reason. */
  open_count: number;
  priority: EventReportPriority;
  /** reason → count, over the filtered set, same as `report_count`. */
  reasons: Partial<Record<EventReportReason, number>>;
  last_reported_at: string | null;
}

export interface ApiEventReport {
  id: string;
  reason: EventReportReason;
  details: string | null;
  status: EventReportStatus;
  created_at: string;
  /** Null for an anonymous report — a normal state, not missing data. */
  reporter: { id: string; email: string } | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  reviewer_note: string | null;
}

export const adminEventReportsApi = {
  /** `open_count` is counted independently of the filter, same as the support
   *  inbox's `awaiting_count`: "how much is waiting on us", not "how many rows
   *  are on screen". */
  list(opts?: {
    status?: EventReportStatus;
    reason?: EventReportReason;
    page?: number;
    perPage?: number;
  }) {
    const query = new URLSearchParams();
    if (opts?.status) query.set("status", opts.status);
    if (opts?.reason) query.set("reason", opts.reason);
    if (opts?.page) query.set("page", String(opts.page));
    if (opts?.perPage) query.set("per_page", String(opts.perPage));
    const suffix = query.toString() ? `?${query}` : "";

    return api.get<{
      reports: ApiEventReportGroup[];
      meta: ApiPageMeta;
      open_count: number;
    }>(`/admin/event_reports${suffix}`);
  },

  /** Deliberately unfiltered — a reviewer deciding whether an event stays up
   *  wants everything said about it, not the slice that matched the filter
   *  they arrived through. `reports` is capped server-side; `total_count` is
   *  what's actually there, so a truncated list can't read as the whole. */
  event(eventId: string) {
    return api.get<{
      event: ApiReportedEventSummary;
      reports: ApiEventReport[];
      total_count: number;
    }>(`/admin/event_reports/events/${eventId}`);
  },

  /** Closes every live report on the event at once, because the decision was
   *  about the event. Deliberately does NOT suspend or unpublish — taking an
   *  event down is `adminApi.suspendEvent`, its own act with its own audit
   *  entry, so the record shows it was chosen rather than implied by closing
   *  a ticket. */
  resolve(eventId: string, status: "actioned" | "dismissed", note?: string) {
    return api.post<{ resolved: number; status: string }>(
      `/admin/event_reports/events/${eventId}/resolve`,
      { status, note: note?.trim() || undefined },
    );
  },
};

/** Present on `/auth/me` only while a staff support session is driving the
 *  request. `by_admin` is always true when the object exists — it's there so
 *  the shape reads correctly at the call site rather than as a bare truthiness
 *  check on an options bag. */
export interface ApiImpersonationState {
  by_admin: true;
  reason: string;
  expires_at: string;
}

export interface ApiImpersonation {
  id: string;
  admin: { id: string; email: string };
  user: { id: string; email: string };
  reason: string;
  expires_at: string;
  ended_at: string | null;
  revoked_at: string | null;
  revoked_by: string | null;
  live: boolean;
  ip: string | null;
  created_at: string;
}

/**
 * Staff support sessions — see docs/impersonation-design.md.
 *
 * Every call here goes out with the **admin's own** token (`api.asAdmin`),
 * never the impersonation token. Three of the four are writes, which a support
 * session refuses outright, and all four are admin-console endpoints, which
 * 404 under an impersonation token. Sending the right credential is what makes
 * "exit" work from inside a session rather than erroring.
 */
export const adminImpersonationApi = {
  /** Returns the session token. The caller stores it under the impersonation
   *  key — never over `rally_token`. */
  start(userId: string, reason: string) {
    return api.asAdmin.post<{ impersonation: ApiImpersonation; token: string }>(
      "/admin/impersonations",
      { user_id: userId, reason },
    );
  },

  /** Idempotent: a session that already expired or was revoked still resolves.
   *  The caller's intent is "I'm done", and an error would leave the frontend
   *  holding a dead token and a toast it can do nothing about. */
  end() {
    return api.asAdmin.delete<{ ended: boolean }>("/admin/impersonations/current");
  },

  list() {
    return api.asAdmin.get<{ impersonations: ApiImpersonation[]; live_count: number }>(
      "/admin/impersonations",
    );
  },

  /** Any admin may revoke any live session, including another admin's — the
   *  case this exists for is the laptop left open, and a control only its own
   *  holder can pull isn't one. */
  revoke(id: string) {
    return api.asAdmin.post<{ impersonation: ApiImpersonation }>(
      `/admin/impersonations/${id}/revoke`,
    );
  },
};
