/**
 * Sitemap generation, run at **build time** — see `scripts/build-sitemap.mjs`.
 *
 * ## Why this isn't a route
 *
 * It used to be: `src/routes/sitemap[.]xml.ts` exported a `server:` handler.
 * This app has no server. `vite.config.ts` registers no nitro plugin, so
 * TanStack Start's per-request build is never wired up; the deploy syncs
 * `dist/client/` only, and nothing in there can execute a handler. CloudFront
 * then maps 404 → 200 `/index.html`, so `GET /sitemap.xml` didn't even fail
 * honestly — it returned the SPA shell with `Content-Type: text/html` and a
 * 200, which Search Console reports as an unreadable sitemap rather than a
 * missing one.
 *
 * It worked perfectly under `npm run dev`, which runs a real server. That is
 * why it survived: the failure only exists in the environment nobody tests in.
 *
 * ## Everything here fails loudly
 *
 * The original swallowed a 422 into an empty list, so the sitemap shipped with
 * two entries and looked exactly like a working one. Nothing in this file
 * degrades: a missing base URL, an unreachable API or a non-2xx response all
 * throw and take the build down with them. A broken deploy gets fixed; a
 * silently-empty sitemap gets discovered months later in Search Console.
 */

/**
 * Page size for the crawl.
 *
 * **Coupled to `EventIndexRequestSchema::MAX_PER_PAGE` (50) in the backend**,
 * which is enforced with `lteq?` and deliberately not clamped — its own
 * comment says "?per_page=100000 is a client bug, and a 422 says so instead of
 * pretending it worked". The old route asked for 1000 and was exactly that
 * client bug. Two repositories of truth for one number, so a spec pins this at
 * or under the cap; if the backend ever lowers it, that test fails here rather
 * than the sitemap silently emptying in production.
 */
export const SITEMAP_MAX_PER_PAGE = 50;

/** Guards against a runaway loop if `meta.total_pages` is ever nonsense. At
 *  50 per page this is 25,000 events, far beyond anything plausible. */
const MAX_PAGES = 500;

export interface SitemapEvent {
  id: string;
  updated_at: string | null;
  organization: { slug: string } | null;
}

interface SitemapEntry {
  path: string;
  changefreq: "daily" | "weekly" | "monthly";
  priority: string;
  lastmod?: string | null;
}

/**
 * Every published, publicly-visible event, walked page by page.
 *
 * **The endpoint is load-bearing, not incidental.** `/api/v1/events` is
 * `Event.publicly_visible`, which is what excludes unlisted events — and per
 * `.claude/rules/events-and-moderation.md`, anything that lists events to
 * strangers has to go through that scope. A sitemap is the most literal
 * listing-to-strangers there is, and publishing an unlisted event to Google is
 * the one mistake in this file that can't be taken back. Don't reach for a
 * different source to make this faster.
 *
 * `fetch` is injected so the tests never touch the network.
 */
export async function fetchAllEvents({
  apiUrl,
  fetch: fetchFn,
}: {
  apiUrl: string;
  fetch: (url: string) => Promise<Response>;
}): Promise<SitemapEvent[]> {
  const events: SitemapEvent[] = [];
  let page = 1;
  let totalPages = 1;

  do {
    const url = `${apiUrl.replace(/\/$/, "")}/api/v1/events?page=${page}&per_page=${SITEMAP_MAX_PER_PAGE}`;

    // Node's bare network error is the string "fetch failed", which in a CI
    // log says nothing about which host was unreachable or what was even being
    // attempted. Re-thrown with the URL attached, and `cause` kept so the
    // original stack survives.
    const response = await fetchFn(url).catch((error: unknown) => {
      throw new Error(`sitemap: could not reach ${url}`, { cause: error });
    });

    // No `res.ok` check that falls through to an empty array. That is the
    // whole bug: a 422 is not a thrown error, so the old `catch` never ran and
    // `events` stayed `[]` with nothing logged.
    if (!response.ok) {
      throw new Error(
        `sitemap: ${url} returned ${response.status}. ` +
          `Refusing to build a sitemap from a partial event list.`,
      );
    }

    const body = (await response.json()) as {
      events?: SitemapEvent[];
      meta?: { total_pages?: number };
    };

    events.push(...(body.events ?? []));
    totalPages = body.meta?.total_pages ?? 1;
    page += 1;
  } while (page <= totalPages && page <= MAX_PAGES);

  return events;
}

/**
 * The XML. Throws rather than emitting anything a crawler would reject.
 */
export function generateSitemap({
  baseUrl,
  events,
}: {
  baseUrl: string;
  events: SitemapEvent[];
}): string {
  assertAbsoluteBaseUrl(baseUrl);
  const origin = baseUrl.replace(/\/$/, "");

  // Derived from events because there is still no public organizers endpoint —
  // the same approach the old route took, and the one part of it that was
  // right. A Map keyed on slug dedupes organizers running several events.
  const organizers = new Map<string, string | null>();
  for (const event of events) {
    const slug = event.organization?.slug;
    if (slug && !organizers.has(slug)) organizers.set(slug, event.updated_at);
  }

  const entries: SitemapEntry[] = [
    { path: "/", changefreq: "daily", priority: "1.0" },
    { path: "/events", changefreq: "daily", priority: "0.9" },
    ...events.map((event): SitemapEntry => ({
      path: `/events/${event.id}`,
      changefreq: "daily",
      priority: "0.8",
      lastmod: event.updated_at,
    })),
    ...[...organizers].map(([slug, updatedAt]): SitemapEntry => ({
      path: `/organizers/${slug}`,
      changefreq: "weekly",
      priority: "0.7",
      lastmod: updatedAt,
    })),
  ];

  const urls = entries.map((entry) =>
    [
      "  <url>",
      `    <loc>${escapeXml(origin + entry.path)}</loc>`,
      `    <changefreq>${entry.changefreq}</changefreq>`,
      `    <priority>${entry.priority}</priority>`,
      // Omitted entirely when absent — `<lastmod></lastmod>` is invalid, and an
      // invalid element can invalidate the whole document rather than one entry.
      entry.lastmod ? `    <lastmod>${toDate(entry.lastmod)}</lastmod>` : null,
      "  </url>",
    ]
      .filter(Boolean)
      .join("\n"),
  );

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...urls,
    "</urlset>",
    "",
  ].join("\n");
}

/**
 * Points `robots.txt` at an absolute sitemap URL.
 *
 * `public/robots.txt` ships `Sitemap: /sitemap.xml`. The directive requires an
 * absolute URL, so a relative one is ignored — meaning even a perfect sitemap
 * stays undiscovered. The static file can't hardcode the host because it
 * differs per environment, so the build rewrites the line into `dist/client/`
 * and the committed file keeps its relative placeholder for local use.
 *
 * Idempotent: rebuilding, or running against an already-rewritten file,
 * produces the same output rather than stacking directives.
 */
export function robotsWithSitemap(robotsTxt: string, baseUrl: string): string {
  assertAbsoluteBaseUrl(baseUrl);
  const directive = `Sitemap: ${baseUrl.replace(/\/$/, "")}/sitemap.xml`;

  if (/^Sitemap:/m.test(robotsTxt)) {
    // Function replacement, not a string: `String#replace` treats `$&`, `$1`
    // and friends in the replacement as patterns, so a base URL containing a
    // `$` would be silently mangled. Returning it from a callback passes it
    // through literally.
    return robotsTxt.replace(/^Sitemap:.*$/m, () => directive);
  }

  return `${robotsTxt.replace(/\s*$/, "")}\n\n${directive}\n`;
}

/**
 * Merges `.env` files with the real environment, the way Vite does.
 *
 * Needed because the build script is a **separate Node process**. Vite loads
 * `.env.local` for the bundle, but `node scripts/build-sitemap.mjs` inherits
 * only `process.env` — so the workflow `.env.example` documents ("copy to
 * .env.local, run npm run build") failed with "VITE_BASE_URL is not set". The
 * fail-loudly path firing for the wrong reason is still a bug.
 *
 * **Not Vite's own `loadEnv`**, which would be the obvious reuse. Importing
 * `vite` pulls in rolldown's platform-specific native binding to read a few
 * lines of `key=value`; the script would then fail to start anywhere that
 * optional dependency didn't install. Twenty lines of parsing beats a native
 * dependency for this.
 *
 * `files` is lowest-priority-first, and `processEnv` beats all of them — CI
 * and `scripts/deploy.sh` pass real variables, and those must win over
 * whatever is in a developer's working copy.
 */
export function resolveEnv({
  files,
  processEnv,
}: {
  files: Array<{ name: string; contents: string }>;
  processEnv: Record<string, string | undefined>;
}): Record<string, string> {
  const env: Record<string, string> = {};

  for (const file of files) {
    for (const [key, value] of parseEnvFile(file.contents)) {
      env[key] = value;
    }
  }

  // Only VITE_-prefixed keys, matching Vite's own rule. This env feeds build
  // output, so an unprefixed `AWS_SECRET_ACCESS_KEY` sitting in someone's
  // shell must not be reachable from here.
  for (const [key, value] of Object.entries(processEnv)) {
    if (key.startsWith("VITE_") && value !== undefined) env[key] = value;
  }

  return env;
}

function parseEnvFile(contents: string): Array<[string, string]> {
  const out: Array<[string, string]> = [];

  for (const rawLine of contents.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!match) continue;

    const [, key, rawValue] = match;
    if (!key.startsWith("VITE_")) continue;

    let value = rawValue.trim();
    // Strip one layer of matching quotes. Unquoted values keep everything
    // after `=` — a `#` inside a URL fragment is part of the value, not the
    // start of a comment, which is where a naive split-on-# gets it wrong.
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }

    out.push([key, value]);
  }

  return out;
}

/**
 * The check that turns the original silent failure into a loud one.
 *
 * `VITE_BASE_URL` is read in three places (here, `events.$eventId.tsx` and
 * `organizers.$slug.tsx`) and was defined in none — not `.env.example`, not
 * `deploy.yml`, not `scripts/deploy.sh` — so it was always `""` and every
 * `<loc>` came out relative.
 */
function assertAbsoluteBaseUrl(baseUrl: string): void {
  if (!baseUrl) {
    throw new Error(
      "sitemap: VITE_BASE_URL is not set. Every <loc> must be an absolute URL, " +
        "so there is nothing useful to build.",
    );
  }

  if (!/^https?:\/\/[^/]/.test(baseUrl)) {
    throw new Error(
      `sitemap: VITE_BASE_URL must be absolute and include a scheme (got "${baseUrl}").`,
    );
  }
}

/** `2026-09-18T04:30:00.000Z` → `2026-09-18`. The spec allows a full
 *  timestamp, but a bare date is what crawlers act on and it keeps diffs
 *  between builds small. */
function toDate(timestamp: string): string {
  return timestamp.split("T")[0];
}

/** Ids are UUIDs and slugs are slugs, so nothing here needs escaping today.
 *  It's here because a `&` reaching a `<loc>` would break the whole document,
 *  not just its own entry — a bad trade to leave to chance. */
function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
