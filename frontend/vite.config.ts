import { defineConfig } from "vite";
import viteReact from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import tsConfigPaths from "vite-tsconfig-paths";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";

// Previously wrapped in @lovable.dev/vite-tanstack-config, a config helper
// built for apps developed inside Lovable's hosted editor/sandbox. Removed
// (2026-08-19) because everything that package added beyond the plugins
// below only activates when LOVABLE_SANDBOX=1 / DEV_SERVER__PROJECT_PATH are
// set — i.e. inside Lovable's own cloud sandbox, which this app never runs
// in (it's developed directly in this repo and deploys via
// .github/workflows/deploy.yml to S3 + CloudFront, not Lovable's
// infrastructure). Every plugin it actually wired up outside that sandbox
// (Tailwind, tsconfig-paths, TanStack Start, React — nitro was already off
// via nitro: false below) was already a direct dependency in package.json;
// this file just assembles them directly instead of through that wrapper.
export default defineConfig(({ command, mode }) => ({
  css: { transformer: "lightningcss" },

  resolve: {
    // vite-tsconfig-paths (below) already resolves "@/*" from tsconfig.json,
    // this is just a belt-and-suspenders duplicate matching what the old
    // wrapper set, kept for zero behavior change.
    alias: { "@": `${process.cwd()}/src` },
    dedupe: [
      "react",
      "react-dom",
      "react/jsx-runtime",
      "react/jsx-dev-runtime",
      "@tanstack/react-query",
      "@tanstack/query-core",
    ],
  },

  optimizeDeps: {
    include: [
      "react",
      "react-dom",
      "react-dom/client",
      "react/jsx-runtime",
      "react/jsx-dev-runtime",
    ],
    ignoreOutdatedRequests: true,
  },

  server: {
    host: "::",
    port: 8080,
    // Debounces file-watch events so an editor that writes a file in
    // multiple steps (save-then-flush) doesn't trigger a double reload.
    watch: { awaitWriteFinish: { stabilityThreshold: 1000, pollInterval: 100 } },
  },

  // Only applies to `npm run build:dev` (vite build --mode development) —
  // keeps readable output for a dev-mode build instead of minified/mangled
  // names, and pins NODE_ENV to "development" in the client bundle.
  ...(command === "build" && mode === "development"
    ? {
        environments: {
          client: { define: { "process.env.NODE_ENV": JSON.stringify("development") } },
        },
        esbuild: { keepNames: true },
      }
    : {}),

  plugins: [
    tailwindcss(),
    tsConfigPaths({ projects: ["./tsconfig.json"] }),
    // This app deploys as a static site on S3 + CloudFront
    // (infrastructure/frontend.tf), which can only serve files — there's
    // nowhere to run a server. No nitro() plugin is registered here at all
    // (equivalent to the old wrapper's `nitro: false`), so TanStack Start's
    // own per-request SSR build never gets wired up. `spa.enabled` instead
    // prerenders one HTML shell at build time (crawling from "/"); every
    // route then hydrates and renders client-side from that same shell,
    // same as a classic SPA. `outputPath: "/index"` makes that shell land at
    // `dist/client/index.html` — the file CloudFront's default_root_object
    // and its 404/403→/index.html fallback (for deep-linked routes like
    // /events/:id) both expect. See README's deploy section: only
    // `dist/client/` gets synced to S3, not the whole `dist/` directory.
    tanstackStart({
      importProtection: {
        behavior: "error",
        client: { files: ["**/server/**"], specifiers: ["server-only"] },
      },
      spa: { enabled: true, prerender: { outputPath: "/index" } },
    }),
    viteReact(),
  ],
}));
