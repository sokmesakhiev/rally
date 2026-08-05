/**
 * Google reCAPTCHA v3 — invisible bot protection for account creation
 * (AuthController#signup). No checkbox, no challenge UI: grecaptcha scores
 * the request in the background and we ask for a token right before
 * submitting the sign-up form.
 *
 * Gracefully degrades: without VITE_RECAPTCHA_SITE_KEY configured,
 * getRecaptchaToken() resolves to undefined immediately and no script is
 * ever loaded — signup still works with no token, since the backend
 * (RecaptchaVerifier) only enforces verification once RECAPTCHA_SECRET_KEY
 * is also set server-side. Same fallback philosophy as LocationPicker and
 * GoogleSignInButton.
 *
 * No npm package needed — loaded via Google's official <script> tag rather
 * than a bundled library, same approach as GoogleSignInButton for Identity
 * Services.
 */

const RECAPTCHA_SITE_KEY = import.meta.env.VITE_RECAPTCHA_SITE_KEY as string | undefined;

// Minimal shape of the grecaptcha global we actually use — there's no
// official @types package for this.
interface Grecaptcha {
  ready(callback: () => void): void;
  execute(siteKey: string, options: { action: string }): Promise<string>;
}
declare global {
  interface Window {
    grecaptcha?: Grecaptcha;
  }
}

// Loaded once and reused — guards against this being called more than once
// (e.g. a user submitting the form, failing validation, and submitting
// again) appending the script multiple times.
let scriptLoadPromise: Promise<Grecaptcha> | null = null;
function loadRecaptchaScript(siteKey: string): Promise<Grecaptcha> {
  if (scriptLoadPromise) return scriptLoadPromise;
  scriptLoadPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>("script[data-recaptcha-v3]");
    const onReady = () => {
      if (!window.grecaptcha) {
        reject(new Error("grecaptcha failed to initialize"));
        return;
      }
      window.grecaptcha.ready(() => resolve(window.grecaptcha!));
    };

    if (existing) {
      onReady();
      return;
    }

    const script = document.createElement("script");
    script.src = `https://www.google.com/recaptcha/api.js?render=${encodeURIComponent(siteKey)}`;
    script.async = true;
    script.defer = true;
    script.dataset.recaptchaV3 = "true";
    script.onload = onReady;
    script.onerror = () => reject(new Error("Failed to load reCAPTCHA"));
    document.head.appendChild(script);
  });
  return scriptLoadPromise;
}

/**
 * Returns a fresh reCAPTCHA v3 token scoped to `action` (must match the
 * `action:` the backend expects — see RecaptchaVerifier.verify), or
 * `undefined` if reCAPTCHA isn't configured or fails to load. Never throws —
 * callers should send whatever comes back (including undefined) to the
 * backend and let it decide whether a missing token is acceptable.
 */
export async function getRecaptchaToken(action: string): Promise<string | undefined> {
  if (!RECAPTCHA_SITE_KEY) return undefined;

  try {
    const grecaptcha = await loadRecaptchaScript(RECAPTCHA_SITE_KEY);
    return await grecaptcha.execute(RECAPTCHA_SITE_KEY, { action });
  } catch {
    // Ad blockers, network issues, etc. Let the backend's own "missing
    // token" handling take it from here rather than blocking the submit
    // client-side.
    return undefined;
  }
}
