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

// ─── Token helpers ────────────────────────────────────────────────────────────

export function getToken(): string | null {
  return typeof window !== "undefined" ? localStorage.getItem(TOKEN_KEY) : null;
}

export function setToken(token: string): void {
  if (typeof window !== "undefined") localStorage.setItem(TOKEN_KEY, token);
}

export function clearToken(): void {
  if (typeof window !== "undefined") localStorage.removeItem(TOKEN_KEY);
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
): Promise<T> {
  const headers: Record<string, string> = {};
  const token = getToken();
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
  /** Drives whether the admin nav link renders. NOT a security boundary —
   * every admin endpoint re-checks server-side. */
  admin?: boolean;
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
  brand_color: string;
  banner_url: string | null;
  logo_url: string | null;
  /** Organizer-uploaded .odt certificate-of-participation template. Null
   * means the feature is off for this event — no certificates are generated. */
  certificate_template_url: string | null;
  created_at: string;
  updated_at: string;
  registrations_count?: number;
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
  /** Never the plaintext key — see payway_api_key_masked. */
  payway_merchant_id: string | null;
  payway_api_key_masked: string | null;
  payway_configured: boolean;
  /** Opt-out notification preferences — all default true. Only cover
   * RegistrationMailer's non-essential emails; password resets, email
   * verification, and the initial registration confirmation are always sent. */
  notify_payment_received: boolean;
  notify_refund_issued: boolean;
  notify_promoted_from_waitlist: boolean;
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
}

// ─── Auth ─────────────────────────────────────────────────────────────────────

export const authApi = {
  async signup(email: string, password: string, displayName?: string, recaptchaToken?: string) {
    const res = await api.post<{ token: string; user: ApiUser }>("/auth/signup", {
      email,
      password,
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

  async me() {
    return api.get<{ user: ApiUser }>("/auth/me");
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
      event_types_attributes?: (ApiEventTypeDraft & { id?: string; _destroy?: boolean })[];
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

  // Organizer-only — the count of participants for one of *their* events.
  // For public capacity display, use the event's own `registrations_count`
  // (returned by eventsApi.get, no auth required) instead.
  forEvent(eventId: string) {
    return api.get<{ registrations: ApiRegistration[] }>(`/events/${eventId}/registrations`);
  },

  /** Downloads the participant list as a CSV (name, email, event type(s),
   * payment/check-in status, plus one column per survey question) for
   * offline use — check-in sheets, mail merges. Organizer-only, same
   * authorization as forEvent(). Triggers a browser file download rather
   * than returning parsed data. */
  exportCsv(eventId: string) {
    return downloadFile(
      `/events/${eventId}/registrations/export`,
      `registrations-${eventId}.csv`,
    );
  },

  /** `guest` is only needed when the visitor isn't signed in (see
   * useAuth()'s `user`) — the backend requires a name plus at least one of
   * email/phone (phone is Cambodia's most common contact channel, so it's
   * a first-class alternative to email, not a fallback). On a successful
   * guest registration the response includes `auth: { token, user }`, the
   * same shape authApi.signup/signin/google return; this stores the token
   * immediately so the very next authenticated call (payment creation, "My
   * registrations") works without the caller having to do anything extra.
   * Call useAuth()'s `refresh()` afterward to pick up the new `user` in
   * context. */
  async create(
    eventId: string,
    opts?: {
      answers?: ApiRegistrationAnswer[];
      eventTypeIds?: string[];
      guest?: { name: string; email?: string; phone?: string };
    },
  ) {
    const res = await api.post<{
      registration: ApiRegistration;
      auth?: { token: string; user: ApiUser };
    }>(`/events/${eventId}/registrations`, {
      answers: opts?.answers ?? [],
      event_type_ids: opts?.eventTypeIds ?? [],
      guest: opts?.guest,
    });
    if (res.auth) setToken(res.auth.token);
    return res;
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
    return api.patch<{ result: { id: string; registration_id: string; finish_time_seconds: number | null } }>(
      `/registrations/${id}/result`,
      { result: { finish_time_seconds: finishTimeSeconds } },
    );
  },
};

// ─── Results (finish times) ────────────────────────────────────────────────────

export interface ApiResultsImportSummary {
  updated: number;
  errors: Array<{ row: number; email: string; reason: string }>;
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
    return waitlistApi.mine().then((r) => r.waitlist_entries.find((e) => e.event_id === eventId) ?? null);
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

// ─── Uploads ──────────────────────────────────────────────────────────────────

export const uploadsApi = {
  async upload(
    file: File,
    type: "banner" | "logo" | "avatar" | "certificate_template",
  ): Promise<string> {
    const form = new FormData();
    form.append("file", file);
    form.append("type", type);
    const res = await api.upload<{ url: string }>("/uploads", form);
    return res.url;
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

export const paymentsApi = {
  create(registrationId: string) {
    return api.post<{ payment: ApiPayment }>(`/registrations/${registrationId}/payments`);
  },

  status(paymentId: string) {
    return api.get<{ payment: ApiPayment }>(`/payments/${paymentId}`);
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


  users(opts?: { q?: string; status?: "all" | "active" | "suspended"; page?: number; perPage?: number }) {
    const params = new URLSearchParams();
    if (opts?.q?.trim()) params.set("q", opts.q.trim());
    if (opts?.status && opts.status !== "all") params.set("status", opts.status);
    if (opts?.page) params.set("page", String(opts.page));
    if (opts?.perPage) params.set("per_page", String(opts.perPage));

    const qs = params.toString();
    return api.get<{ users: ApiAdminUser[]; meta: ApiPageMeta }>(`/admin/users${qs ? `?${qs}` : ""}`);
  },

  /** Also unpublishes every event the user created — see User#suspend!. */
  suspendUser(id: string, reason?: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/suspend`, { reason });
  },

  /** Does NOT re-publish events the suspension took down. */
  unsuspendUser(id: string) {
    return api.post<{ user: ApiAdminUser }>(`/admin/users/${id}/unsuspend`);
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
   * Irreversible, and rejected server-side if the event has paid
   * registrations. `confirm` is required by the API — passed explicitly rather
   * than defaulted so a stray call can't delete anything.
   */
  deleteEvent(id: string) {
    return api.delete<{ message: string }>(`/admin/events/${id}?confirm=true`);
  },
};
