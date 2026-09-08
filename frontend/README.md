# Rally — frontend

The React 19 client for Rally, an event registration platform for running,
cycling, swimming and triathlon events in Cambodia.

Built on TanStack Start with file-based routing, Vite, Tailwind v4 and
shadcn/ui. It talks to the Rails API in [`../backend`](../backend) over JSON
and deploys independently of it.

**Architecture and the reasoning behind the design live in
[`../CLAUDE.md`](../CLAUDE.md)**; routing conventions live in
[`src/routes/README.md`](src/routes/README.md). This file is about getting it
running and working on it day to day, and links to those rather than repeating
them — duplicated docs drift, and the stale copy is the one that misleads.

## Requirements

Node 24 (what CI builds with). There's no `.nvmrc` or `engines` field, so
nothing enforces it locally.

## Install

```sh
npm ci
```

### Use npm, not bun

Both `bun.lock` and `package-lock.json` are committed, and **`bun.lock` is
stale to the point of being unusable.** Dependabot only updates
`package-lock.json`, and CI installs with `npm ci`, so `package-lock.json` is
the one that reflects reality. As of this writing `bun.lock` doesn't merely
lag — it doesn't contain `vitest` or `i18next` at all, so it predates both the
test suite and internationalisation, and it pins TypeScript 5.9 and ESLint 9
against the 6.x and 10.x the app actually builds with.

`bun install` would give you a tree that can't run the tests and doesn't match
what gets deployed. If you hit a bug CI can't reproduce, check this first.

`bun.lock` should probably be deleted rather than maintained — nothing in CI
or deployment reads it.

When debugging a dependency problem, clear the tree first:

```sh
rm -rf node_modules && npm ci
```

A warm `node_modules` masks peer-dependency conflicts, which is how a broken
lockfile reaches CI unnoticed.

## Environment

```sh
cp .env.example .env.local
```

Only `VITE_API_URL` matters to get started. Every other variable gates an
optional integration off entirely when unset — Google Maps, Google sign-in,
reCAPTCHA and Sentry all degrade to a working app without them.
`.env.example` documents each one; read it there.

Anything prefixed `VITE_` is **compiled into the public bundle**. Never put a
secret in one. The keys here are all publishable by design (a Sentry DSN is a
write-only ingest endpoint; a Google client ID is public); their backend
counterparts hold the secrets.

## Running it

```sh
npm run dev        # http://localhost:8080
```

### Ports don't line up out of the box

| Thing | Port |
|---|---|
| Vite dev server | 8080 |
| Rails (`bin/rails server`) | 3000 |
| What this app expects the API on (`VITE_API_URL` default) | **3001** |

A default `npm run dev` and a default `bin/rails server` will not talk to each
other. Either set `VITE_API_URL=http://localhost:3000` in `.env.local`, or
start Rails with `bin/rails server -p 3001`.

Note also that the backend's `.env.example` ships
`FRONTEND_URL=http://localhost:5173` — Vite's generic default, not this
project's 8080. It matters for CORS and email links.

## Tests

Vitest with jsdom and Testing Library. Config is `vitest.config.ts`, kept
deliberately separate from `vite.config.ts` (see the comment there for why).

```sh
npm test               # once
npm run test:watch
npm run test:coverage  # what CI runs
```

Coverage excludes `src/components/ui/**` (vendored shadcn primitives) and
generated files.

## Lint and format

```sh
npm run lint
npm run format     # prettier --write .
```

**`npm run lint` currently fails**, with a backlog of pre-existing problems —
largely new rules from an `eslint-plugin-react-hooks` v7 bump applied to
existing code, plus `no-explicit-any` on `catch (e: any)` handlers. There is
**no ESLint step in CI**, so this doesn't gate anything today. Treat a
non-zero exit as expected and check that your own files are clean rather than
the total count.

## Build

```sh
npm run build      # → dist/client/
```

**This produces a static SPA, not a server-rendered app**, despite being
TanStack Start. No `nitro()` plugin is registered, so Start's per-request SSR
build never gets wired up; `spa.enabled` prerenders a single HTML shell at
build time and every route hydrates client-side from it.

That matches the deploy target — S3 and CloudFront can serve files, not run a
server. Two consequences worth knowing:

- Only `dist/client/` is deployed. `dist/server/` is just the build-time
  prerender driver.
- `src/server.ts` is **dead code** — a Cloudflare Workers `fetch` handler that
  nothing invokes unless a `nitro()` plugin is added back.

## Conventions

- **`src/routeTree.gen.ts` is generated.** Never hand-edit it.
- **All API calls go through `src/lib/api-client.ts`**, a hand-written fetch
  wrapper. The JWT lives in `localStorage` under `rally_token`;
  `src/lib/use-auth.tsx` wraps it in a context. Don't call `fetch` directly
  from components.
- **`src/components/ui/` is vendored shadcn/ui.** Treated as out of scope for
  app-level work — lint, i18n and coverage all exclude it. Prefer composing
  these over adding another UI library.
- **Every user-facing string goes through `t("namespace.key")`.** Locales are
  `src/i18n/locales/en.json` (source of truth) and `km.json` (Khmer). Add a key
  to one and you must add it to the other, or Khmer silently falls back to
  English. The app always boots in English and applies the stored preference
  after mount — the prerendered shell is shared by every visitor, so doing it
  synchronously would cause a hydration mismatch.

See [`../CLAUDE.md`](../CLAUDE.md) for the rest, including the parts that are
easy to get wrong.
