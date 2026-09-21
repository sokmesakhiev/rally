import { describe, it, expect, vi } from "vitest";

import {
  SITEMAP_MAX_PER_PAGE,
  fetchAllEvents,
  generateSitemap,
  resolveEnv,
  robotsWithSitemap,
  type SitemapEvent,
} from "@/lib/sitemap";

/**
 * The sitemap is generated at **build time** into `dist/client/`, not served
 * from a route. `src/routes/sitemap[.]xml.ts` was a `server:` handler, and this
 * app has no server: `vite.config.ts` registers no nitro plugin, the deploy
 * syncs `dist/client/` only, and CloudFront maps 404 → 200 `/index.html`. So
 * `GET /sitemap.xml` in production returned the HTML shell with a 200 and
 * `Content-Type: text/html` — which Search Console reads as an unreadable
 * sitemap rather than a missing one. It worked perfectly in `npm run dev`,
 * which is why it survived.
 *
 * This file covers the pure half (build the XML, page the API, rewrite
 * robots.txt). The thin script that reads env and writes files is not tested;
 * everything with a decision in it lives here.
 *
 * Every assertion below corresponds to a defect that shipped. None of them is
 * hypothetical.
 */

function event(overrides: Partial<SitemapEvent> = {}): SitemapEvent {
  return {
    id: "11111111-2222-3333-4444-555555555555",
    updated_at: "2026-09-18T04:30:00.000Z",
    organization: null,
    ...overrides,
  };
}

/** A fetch double that serves `pages` in order and records every URL asked for. */
function fakeApi(pages: Array<{ events: SitemapEvent[]; total_pages: number }>) {
  const urls: string[] = [];
  const fetchFn = vi.fn(async (url: string) => {
    urls.push(url);
    const page = Number(new URL(url, "http://x").searchParams.get("page") ?? "1");
    const body = pages[page - 1] ?? { events: [], total_pages: pages.length };
    return new Response(
      JSON.stringify({
        events: body.events,
        meta: { page, per_page: SITEMAP_MAX_PER_PAGE, total_pages: body.total_pages },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  });
  return { fetchFn, urls };
}

describe("generateSitemap", () => {
  // The defect: BASE_URL was `import.meta.env.VITE_BASE_URL || ""`, and
  // VITE_BASE_URL is defined nowhere — not in .env.example, not in deploy.yml,
  // not in scripts/deploy.sh. So every entry read `<loc>/events/123</loc>`.
  // The sitemap protocol requires absolute URLs; relative ones are dropped.
  it("emits absolute URLs for every entry", () => {
    const xml = generateSitemap({
      baseUrl: "https://rally.example",
      events: [event({ id: "evt-1" })],
    });

    const locs = [...xml.matchAll(/<loc>(.*?)<\/loc>/g)].map((m) => m[1]);

    expect(locs.length).toBeGreaterThan(0);
    expect(locs).toContain("https://rally.example/events/evt-1");
    for (const loc of locs) {
      expect(loc).toMatch(/^https?:\/\//);
    }
  });

  it("includes the home page, the listing, every event and every organizer", () => {
    const xml = generateSitemap({
      baseUrl: "https://rally.example",
      events: [
        event({ id: "evt-1", organization: { slug: "phnom-penh-runners" } }),
        event({ id: "evt-2", organization: { slug: "phnom-penh-runners" } }),
        event({ id: "evt-3", organization: null }),
      ],
    });

    const locs = [...xml.matchAll(/<loc>(.*?)<\/loc>/g)].map((m) => m[1]);

    expect(locs).toEqual(
      expect.arrayContaining([
        "https://rally.example/",
        "https://rally.example/events",
        "https://rally.example/events/evt-1",
        "https://rally.example/events/evt-2",
        "https://rally.example/events/evt-3",
        "https://rally.example/organizers/phnom-penh-runners",
      ]),
    );
    // Two events share an organizer; the organizer appears once.
    expect(locs.filter((l) => l.includes("/organizers/"))).toHaveLength(1);
  });

  // Chosen explicitly over "warn and emit the static pages". The bug being
  // fixed *is* a silent degradation — a swallowed 422 that left a sitemap of
  // two entries looking exactly like a working one. A build that fails is a
  // build someone fixes.
  it("refuses to build without an absolute base URL", () => {
    expect(() => generateSitemap({ baseUrl: "", events: [] })).toThrow(/VITE_BASE_URL/);
    expect(() => generateSitemap({ baseUrl: "rally.example", events: [] })).toThrow(/absolute/i);
    expect(() => generateSitemap({ baseUrl: "/rally", events: [] })).toThrow(/absolute/i);
  });

  it("writes lastmod as a bare date, and omits it when the event has none", () => {
    const xml = generateSitemap({
      baseUrl: "https://rally.example",
      events: [
        event({ id: "dated", updated_at: "2026-09-18T04:30:00.000Z" }),
        event({ id: "undated", updated_at: null }),
      ],
    });

    expect(xml).toContain("<lastmod>2026-09-18</lastmod>");
    // One dated entry only — an empty <lastmod> is invalid, so it's dropped
    // rather than rendered blank.
    expect(xml.match(/<lastmod>/g)).toHaveLength(1);
    expect(xml).not.toContain("<lastmod></lastmod>");
  });

  it("produces a well-formed document with a single urlset root", () => {
    const xml = generateSitemap({ baseUrl: "https://rally.example", events: [event()] });

    expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
    expect(xml).toContain('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');
    expect(xml.match(/<urlset/g)).toHaveLength(1);
    expect(xml.trimEnd().endsWith("</urlset>")).toBe(true);
    expect(
      new DOMParser().parseFromString(xml, "application/xml").querySelector("parsererror"),
    ).toBeNull();
  });
});

describe("fetchAllEvents", () => {
  // The defect: the old route asked for `per_page=1000`.
  // `EventIndexRequestSchema::MAX_PER_PAGE` is 50, enforced with `lteq?` and
  // deliberately *not* clamped — its own comment says "?per_page=100000 is a
  // client bug, and a 422 says so instead of pretending it worked". The route
  // then checked `res.ok`, got false, and fell through to `events = []`. The
  // catch never fired, because a 422 isn't a thrown error.
  it("never requests more per page than the API allows", async () => {
    const { fetchFn, urls } = fakeApi([{ events: [event()], total_pages: 1 }]);

    await fetchAllEvents({ apiUrl: "https://api.example", fetch: fetchFn });

    expect(SITEMAP_MAX_PER_PAGE).toBeLessThanOrEqual(50);
    for (const url of urls) {
      const perPage = Number(new URL(url).searchParams.get("per_page"));
      expect(perPage).toBeLessThanOrEqual(SITEMAP_MAX_PER_PAGE);
    }
  });

  // The other half of the same defect: even at a legal page size, the old
  // route fetched page 1 and stopped, so the sitemap would have capped at 50
  // events forever.
  it("pages until the API says there are no more", async () => {
    const { fetchFn, urls } = fakeApi([
      { events: [event({ id: "a" })], total_pages: 3 },
      { events: [event({ id: "b" })], total_pages: 3 },
      { events: [event({ id: "c" })], total_pages: 3 },
    ]);

    const events = await fetchAllEvents({ apiUrl: "https://api.example", fetch: fetchFn });

    expect(events.map((e) => e.id)).toEqual(["a", "b", "c"]);
    expect(urls.map((u) => new URL(u).searchParams.get("page"))).toEqual(["1", "2", "3"]);
  });

  it("throws on a non-ok response rather than returning nothing", async () => {
    const fetchFn = vi.fn(
      async () =>
        new Response(JSON.stringify({ error: "event.per_page must be less than or equal to 50" }), {
          status: 422,
        }),
    );

    await expect(fetchAllEvents({ apiUrl: "https://api.example", fetch: fetchFn })).rejects.toThrow(
      /422/,
    );
  });

  it("throws when the API is unreachable", async () => {
    const fetchFn = vi.fn(async () => {
      throw new TypeError("fetch failed");
    });

    await expect(
      fetchAllEvents({ apiUrl: "https://api.example", fetch: fetchFn }),
    ).rejects.toThrow();
  });

  /**
   * The safety-critical one.
   *
   * `/api/v1/events` is `Event.publicly_visible`, which is what excludes
   * unlisted events — and per `.claude/rules/events-and-moderation.md`,
   * "anything that lists events to strangers has to go through that scope".
   * A sitemap is the most literal listing-to-strangers there is: publishing an
   * unlisted event to Google is the one failure here nobody can take back.
   *
   * So this pins the *endpoint*, not the filtering. A future change that
   * reaches for a different source to dodge the page cap fails here.
   */
  it("reads the public events endpoint, which is the only scope that hides unlisted events", async () => {
    const { fetchFn, urls } = fakeApi([{ events: [], total_pages: 1 }]);

    await fetchAllEvents({ apiUrl: "https://api.example", fetch: fetchFn });

    expect(urls).not.toHaveLength(0);
    for (const url of urls) {
      expect(new URL(url).pathname).toBe("/api/v1/events");
    }
  });
});

describe("robotsWithSitemap", () => {
  // `public/robots.txt` ships `Sitemap: /sitemap.xml`. The directive requires
  // an absolute URL, so crawlers ignore a relative one — meaning even a
  // perfect sitemap stays undiscovered. The static file can't hardcode the
  // host (it differs per environment), so the build rewrites the line.
  it("rewrites a relative Sitemap directive to an absolute URL", () => {
    const out = robotsWithSitemap(
      "User-agent: *\nAllow: /\n\nSitemap: /sitemap.xml\n",
      "https://rally.example",
    );

    expect(out).toContain("Sitemap: https://rally.example/sitemap.xml");
    expect(out).not.toContain("Sitemap: /sitemap.xml");
    // Everything else is left alone.
    expect(out).toContain("User-agent: *");
    expect(out).toContain("Allow: /");
  });

  it("adds the directive when robots.txt has none", () => {
    const out = robotsWithSitemap("User-agent: *\nAllow: /\n", "https://rally.example");

    expect(out).toContain("Sitemap: https://rally.example/sitemap.xml");
    expect(out.match(/Sitemap:/g)).toHaveLength(1);
  });

  it("is idempotent, so a rebuild doesn't stack directives", () => {
    const once = robotsWithSitemap(
      "User-agent: *\n\nSitemap: /sitemap.xml\n",
      "https://rally.example",
    );
    const twice = robotsWithSitemap(once, "https://rally.example");

    expect(twice).toBe(once);
  });
});

describe("resolveEnv", () => {
  /**
   * The defect this exists for, found in review: `.env.example` says "Copy to
   * .env.local", and the build script was a standalone Node process reading
   * only `process.env`. Vite loads `.env.local` for the *bundle*; a separate
   * process sees none of it. So the documented local workflow — put
   * VITE_BASE_URL in .env.local, run `npm run build` — failed with "VITE_BASE_URL
   * is not set", which is the fail-loudly path firing for entirely the wrong
   * reason.
   *
   * Parsed here rather than via Vite's own `loadEnv` because importing `vite`
   * pulls in rolldown's native binding — a platform-specific .node file — to
   * read four lines of key=value. The script would then fail to start on any
   * machine whose optional dependency didn't install.
   */
  it("reads values out of an env file", () => {
    const env = resolveEnv({
      files: [{ name: ".env.local", contents: "VITE_BASE_URL=https://from-file.example\n" }],
      processEnv: {},
    });

    expect(env.VITE_BASE_URL).toBe("https://from-file.example");
  });

  // CI and scripts/deploy.sh both pass real environment variables, and those
  // must win over whatever happens to be in a developer's checked-out files.
  it("lets process.env win over the files", () => {
    const env = resolveEnv({
      files: [{ name: ".env", contents: "VITE_API_URL=http://from-file:1234\n" }],
      processEnv: { VITE_API_URL: "http://from-ci:9999" },
    });

    expect(env.VITE_API_URL).toBe("http://from-ci:9999");
  });

  // Vite's documented order, lowest priority first. Getting this backwards
  // would mean a committed `.env` silently overriding someone's `.env.local`.
  it("applies files in Vite's precedence order", () => {
    const env = resolveEnv({
      files: [
        { name: ".env", contents: "VITE_BASE_URL=http://base\n" },
        { name: ".env.local", contents: "VITE_BASE_URL=http://local\n" },
        { name: ".env.production", contents: "VITE_BASE_URL=http://prod\n" },
        { name: ".env.production.local", contents: "VITE_BASE_URL=http://prod-local\n" },
      ],
      processEnv: {},
    });

    expect(env.VITE_BASE_URL).toBe("http://prod-local");
  });

  it("handles the shapes real env files come in", () => {
    const env = resolveEnv({
      files: [
        {
          name: ".env",
          contents: [
            "# a comment",
            "",
            "VITE_PLAIN=one",
            'VITE_DQUOTED="two"',
            "VITE_SQUOTED='three'",
            "VITE_SPACED = four ",
            "VITE_EMPTY=",
            "VITE_URL=https://example.com/path?a=b#c",
            "export VITE_EXPORTED=five",
            "NOT_PREFIXED=ignored",
            "malformed line without equals",
          ].join("\n"),
        },
      ],
      processEnv: {},
    });

    expect(env.VITE_PLAIN).toBe("one");
    expect(env.VITE_DQUOTED).toBe("two");
    expect(env.VITE_SQUOTED).toBe("three");
    expect(env.VITE_SPACED).toBe("four");
    expect(env.VITE_EMPTY).toBe("");
    // A `#` inside a value is part of the value, not a comment.
    expect(env.VITE_URL).toBe("https://example.com/path?a=b#c");
    expect(env.VITE_EXPORTED).toBe("five");
    // Only VITE_-prefixed keys, matching Vite's own rule — this env ends up in
    // build output, and a bare `AWS_SECRET_ACCESS_KEY` in someone's shell must
    // not be readable from here.
    expect(env).not.toHaveProperty("NOT_PREFIXED");
  });

  it("ignores files that don't exist", () => {
    expect(() => resolveEnv({ files: [], processEnv: {} })).not.toThrow();
    expect(resolveEnv({ files: [], processEnv: { VITE_A: "x" } }).VITE_A).toBe("x");
  });
});
