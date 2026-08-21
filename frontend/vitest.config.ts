import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

/**
 * Standalone test config, deliberately NOT extending vite.config.ts.
 *
 * vite.config.ts wires up the full TanStack Start plugin chain (tanstackStart,
 * tsconfig-paths, Tailwind). Those exist to build and serve the app; under
 * Vitest they'd try to set up route generation and CSS processing around every
 * test run for no benefit. Reusing only the two plugins tests actually need —
 * React transform and the `@/` path alias from tsconfig — keeps runs fast and
 * avoids coupling the test setup to the rest of the build config.
 */
export default defineConfig({
  plugins: [react()],
  // Resolves the `@/*` alias from tsconfig.json. Vite 8 handles this natively,
  // so no vite-tsconfig-paths plugin is needed (it warns if you use it).
  resolve: { tsconfigPaths: true },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    // Only pick up our own tests — without this, Vitest's default include
    // would also walk node_modules-adjacent .test files in some setups.
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      // Reported-on set is app code only. The ui/ primitives are vendored
      // shadcn components (already excluded from lint/i18n work for the same
      // reason), and generated route/config files aren't meaningfully testable.
      include: ["src/**/*.{ts,tsx}"],
      exclude: [
        "src/components/ui/**",
        "src/routeTree.gen.ts",
        "src/test/**",
        "src/**/*.{test,spec}.{ts,tsx}",
      ],
    },
  },
});
