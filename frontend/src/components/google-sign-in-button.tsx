/**
 * GoogleSignInButton — renders Google's official "Sign in with Google"
 * button via Google Identity Services, used on the sign-in/sign-up page.
 *
 * Gracefully degrades: without VITE_GOOGLE_CLIENT_ID configured, renders
 * nothing (see .env.example) — email/password remains the only sign-in
 * method, same fallback philosophy as LocationPicker for Google Maps.
 *
 * No npm package needed — Identity Services is loaded via its official
 * <script> tag rather than a bundled library, so this feature doesn't add
 * anything to package.json.
 */
import { useEffect, useId, useRef, useState } from "react";

const GOOGLE_CLIENT_ID = import.meta.env.VITE_GOOGLE_CLIENT_ID as string | undefined;
const GSI_SCRIPT_SRC = "https://accounts.google.com/gsi/client";

// Minimal shape of the Google Identity Services global we actually use —
// there's no official @types package for this (unlike @types/google.maps).
interface GoogleCredentialResponse {
  credential: string;
}
interface GoogleAccountsId {
  initialize(config: {
    client_id: string;
    callback: (response: GoogleCredentialResponse) => void;
  }): void;
  renderButton(
    parent: HTMLElement,
    options: { type: string; theme: string; size: string; width: number; text: string },
  ): void;
}
declare global {
  interface Window {
    google?: { accounts: { id: GoogleAccountsId } };
  }
}

// Loaded once and reused — guards against StrictMode's double-invoke and
// this component mounting more than once appending the script twice.
let scriptLoadPromise: Promise<void> | null = null;
function loadGsiScript(): Promise<void> {
  if (scriptLoadPromise) return scriptLoadPromise;
  scriptLoadPromise = new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${GSI_SCRIPT_SRC}"]`)) {
      resolve();
      return;
    }
    const script = document.createElement("script");
    script.src = GSI_SCRIPT_SRC;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Failed to load Google Identity Services"));
    document.head.appendChild(script);
  });
  return scriptLoadPromise;
}

interface GoogleSignInButtonProps {
  /** Called with the signed ID token once the user picks a Google account.
   * The token is verified server-side (AuthController#google) — never
   * trusted as-is on the frontend. */
  onCredential: (idToken: string) => void;
}

export function GoogleSignInButton({ onCredential }: GoogleSignInButtonProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const containerId = useId();
  const [ready, setReady] = useState(false);
  // Read inside the effect via a ref so the setup effect doesn't need
  // `onCredential` in its dependency array (it must only run once).
  const onCredentialRef = useRef(onCredential);
  onCredentialRef.current = onCredential;

  useEffect(() => {
    if (!GOOGLE_CLIENT_ID || !containerRef.current) return;
    let cancelled = false;

    loadGsiScript()
      .then(() => {
        if (cancelled || !containerRef.current || !window.google) return;
        window.google.accounts.id.initialize({
          client_id: GOOGLE_CLIENT_ID,
          callback: (response) => onCredentialRef.current(response.credential),
        });
        window.google.accounts.id.renderButton(containerRef.current, {
          type: "standard",
          theme: "outline",
          size: "large",
          width: 384,
          text: "continue_with",
        });
        setReady(true);
      })
      .catch(() => {
        // Silently no-op — email/password remains available either way.
      });

    return () => {
      cancelled = true;
    };
    // Intentionally runs once per mount only (refs, not reactive values).
  }, []);

  if (!GOOGLE_CLIENT_ID) return null;

  return (
    <div ref={containerRef} id={containerId} className={ready ? "flex justify-center" : "hidden"} />
  );
}
