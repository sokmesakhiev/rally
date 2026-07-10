/**
 * Rails API client — replaces all Supabase queries.
 * Base URL reads from VITE_API_URL (defaults to http://localhost:3001).
 */

const BASE_URL = (
  typeof import.meta !== "undefined"
    ? (import.meta.env?.VITE_API_URL ?? "http://localhost:3001")
    : (process.env.API_URL ?? "http://localhost:3001")
) + "/api/v1";

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
    throw new Error(json.error ?? `API error ${res.status}`);
  }

  return json as T;
}

const api = {
  get:    <T>(path: string) => request<T>("GET", path),
  post:   <T>(path: string, body?: unknown) => request<T>("POST", path, body),
  patch:  <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
  delete: <T>(path: string) => request<T>("DELETE", path),
  upload: <T>(path: string, form: FormData) => request<T>("POST", path, form, true),
};

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ApiUser {
  id: string;
  email: string;
  display_name: string | null;
  avatar_url: string | null;
  email_verified: boolean;
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
  capacity: number | null;       // null = unlimited per type
  price_cents: number | null;    // null = inherit event price
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
  start_at: string;
  end_at: string | null;
  capacity: number | null;
  price_cents: number;
  currency: string;
  is_published: boolean;
  brand_color: string;
  banner_url: string | null;
  logo_url: string | null;
  created_at: string;
  updated_at: string;
  registrations_count?: number;
}

export interface ApiRegistration {
  id: string;
  event_id: string;
  user_id: string;
  status: string;
  payment_status: string;
  amount_paid_cents: number;
  created_at: string;
  event?: ApiEvent;
  event_types: ApiEventType[];
  profile?: { display_name: string | null; avatar_url: string | null };
}

export interface ApiProfile {
  id: string | null;
  user_id: string;
  display_name: string | null;
  avatar_url: string | null;
  created_at: string | null;
  updated_at: string | null;
}

// ─── Auth ─────────────────────────────────────────────────────────────────────

export const authApi = {
  async signup(email: string, password: string, displayName?: string) {
    const res = await api.post<{ token: string; user: ApiUser }>("/auth/signup", {
      email,
      password,
      display_name: displayName,
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

  signout() {
    clearToken();
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
  list() {
    return api.get<{ events: ApiEvent[] }>("/events");
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

  update(id: string, data: Partial<ApiEvent> & { event_types_attributes?: (ApiEventTypeDraft & { id?: string; _destroy?: boolean })[] }) {
    return api.patch<{ event: ApiEvent }>(`/events/${id}`, { event: data });
  },

  delete(id: string) {
    return api.delete<{ message: string }>(`/events/${id}`);
  },
};

// ─── Registrations ────────────────────────────────────────────────────────────

export const registrationsApi = {
  mine() {
    return api.get<{ registrations: ApiRegistration[] }>("/registrations");
  },

  forEvent(eventId: string) {
    return api.get<{ registrations: ApiRegistration[] }>(`/events/${eventId}/registrations`);
  },

  registrationCount(eventId: string) {
    return api
      .get<{ registrations: ApiRegistration[] }>(`/events/${eventId}/registrations`)
      .then((r) => r.registrations.length)
      .catch(() => 0);
  },

  create(eventId: string, opts?: { answers?: ApiRegistrationAnswer[]; eventTypeIds?: string[] }) {
    return api.post<{ registration: ApiRegistration }>(`/events/${eventId}/registrations`, {
      answers: opts?.answers ?? [],
      event_type_ids: opts?.eventTypeIds ?? [],
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

  remove(id: string) {
    return api.delete<{ message: string }>(`/registrations/${id}`);
  },
};

// ─── Profile ──────────────────────────────────────────────────────────────────

export const profileApi = {
  get() {
    return api.get<{ profile: ApiProfile }>("/profile");
  },

  update(data: Partial<ApiProfile>) {
    return api.patch<{ profile: ApiProfile }>("/profile", { profile: data });
  },
};

// ─── Uploads ──────────────────────────────────────────────────────────────────

export const uploadsApi = {
  async upload(file: File, type: "banner" | "logo" | "avatar"): Promise<string> {
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
      `/events/${eventId}/survey_responses`
    );
  },
};

// ─── Payments (ABA PayWay KHQR) ────────────────────────────────────────────────

export type PaymentStatus = "pending" | "approved" | "declined" | "cancelled" | "expired" | "refunded";

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
