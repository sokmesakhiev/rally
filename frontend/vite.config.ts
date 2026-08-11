// @lovable.dev/vite-tanstack-config already includes the following — do NOT add them manually
// or the app will break with duplicate plugins:
//   - tanstackStart, viteReact, tailwindcss, tsConfigPaths, nitro (build-only using cloudflare as a default target),
//     componentTagger (dev-only), VITE_* env injection, @ path alias, React/TanStack dedupe,
//     error logger plugins, and sandbox detection (port/host/strictPort).
// You can pass additional config via defineConfig({ vite: { ... }, etc... }) if needed.
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

export default defineConfig({
  // This app deploys as a static site on S3 + CloudFront (infrastructure/frontend.tf),
  // which can only serve files — there's nowhere to run a server. Left at its
  // default, this package's `nitro()` build wires TanStack Start up as a
  // per-request SSR app targeting Cloudflare Workers (`server.js` + wrangler.json),
  // which `vite build` writes to `.output/`, not `dist/`, and which S3 can't run
  // at all. `nitro: false` skips that and falls back to TanStack Start's own
  // native build, which writes a plain `dist/client/` (static assets) +
  // `dist/server/` (only used locally to drive the prerender below, not deployed).
  //
  // `tanstackStart.spa` prerenders one HTML shell at build time (crawling from
  // "/") instead of rendering per-request; every route hydrates and renders
  // client-side from there, same as a classic SPA. `outputPath: "/index"` makes
  // that shell land at `dist/client/index.html` — the file CloudFront's
  // default_root_object and its 404/403→/index.html fallback (for deep-linked
  // routes like /events/:id) both expect. See README's deploy section: only
  // `dist/client/` gets synced to S3, not the whole `dist/` directory.
  nitro: false,
  tanstackStart: {
    spa: { enabled: true, prerender: { outputPath: "/index" } },
  },
});
