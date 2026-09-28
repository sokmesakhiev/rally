#!/usr/bin/env node
/**
 * Writes `dist/client/sitemap.xml` and rewrites `dist/client/robots.txt`.
 *
 * Runs **after** `vite build` (see package.json's `build` script), because it
 * writes into the build output rather than into `public/`. Writing to
 * `public/` would work — Vite copies it — but it would leave generated files
 * sitting in the repo for someone to commit or hand-edit.
 *
 * All the logic lives in `src/lib/sitemap.ts` and is unit-tested. This file is
 * deliberately dumb: read env, fetch, write, report. Anything with a decision
 * in it belongs next door, where a test can reach it.
 *
 * It exits non-zero on any problem, and that is the design rather than an
 * oversight — see the module header. The bug this replaces swallowed a 422
 * into an empty list and shipped a two-entry sitemap that looked exactly like
 * a working one.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  fetchAllEvents,
  generateSitemap,
  resolveEnv,
  robotsWithSitemap,
} from "../src/lib/sitemap.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = join(root, "dist", "client");

/**
 * Vite's own precedence, lowest first. This process doesn't inherit anything
 * Vite loaded — it's a separate `node` invocation — so the `.env.local`
 * workflow `.env.example` documents has to be read here explicitly.
 *
 * Mode is always "production": both `build` and `build:dev` generate a sitemap
 * for a deployed site, and `build:dev`'s Vite mode only affects bundling.
 */
const ENV_FILES = [".env", ".env.local", ".env.production", ".env.production.local"];

async function loadEnvFiles() {
  const files = [];
  for (const name of ENV_FILES) {
    const contents = await readFile(join(root, name), "utf8").catch(() => null);
    if (contents !== null) files.push({ name, contents });
  }
  return files;
}

async function main() {
  const env = resolveEnv({ files: await loadEnvFiles(), processEnv: process.env });
  const baseUrl = env.VITE_BASE_URL ?? "";
  const apiUrl = env.VITE_API_URL ?? "";

  if (!apiUrl) {
    throw new Error("sitemap: VITE_API_URL is not set, so there is no event list to build from.");
  }

  const events = await fetchAllEvents({ apiUrl, fetch: (url) => fetch(url) });

  // generateSitemap validates baseUrl and throws; fetching first means a
  // misconfigured host fails after one round trip rather than before, which is
  // the right order for the error message people actually see — "the API said
  // 422" is more useful than "VITE_BASE_URL missing" when both are true.
  const xml = generateSitemap({ baseUrl, events });

  await mkdir(outDir, { recursive: true });
  await writeFile(join(outDir, "sitemap.xml"), xml, "utf8");

  // robots.txt is copied into dist by Vite from public/. If it isn't there,
  // the build output is not what this script assumes and guessing would hide
  // that.
  const robotsPath = join(outDir, "robots.txt");
  const robots = await readFile(robotsPath, "utf8").catch(() => {
    throw new Error(
      `sitemap: ${robotsPath} not found. Run this after \`vite build\`, which copies public/.`,
    );
  });
  await writeFile(robotsPath, robotsWithSitemap(robots, baseUrl), "utf8");

  const eventCount = events.length;
  console.log(
    `sitemap: wrote ${eventCount} event${eventCount === 1 ? "" : "s"} ` +
      `to dist/client/sitemap.xml (${baseUrl})`,
  );

  // A build that produced a sitemap with no events is almost certainly a
  // misconfiguration rather than a platform with nothing on it, and it's
  // exactly the state that shipped unnoticed before. Loud, but not fatal —
  // a genuinely empty catalogue is possible on a fresh environment.
  if (eventCount === 0) {
    console.warn(
      "sitemap: WARNING — no published events were returned. " +
        "If that's unexpected, check VITE_API_URL points at the right API.",
    );
  }
}

main().catch((error) => {
  console.error(`\n${error.message}\n`);
  process.exit(1);
});
