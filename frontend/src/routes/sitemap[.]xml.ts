import { createFileRoute } from "@tanstack/react-router";
import type {} from "@tanstack/react-start";

const BASE_URL = import.meta.env.VITE_BASE_URL || "";

interface SitemapEntry {
  path: string;
  changefreq?: "daily" | "weekly" | "monthly";
  priority?: string;
  lastmod?: string;
}

export const Route = createFileRoute("/sitemap.xml")({
  server: {
    handlers: {
      GET: async () => {
        const apiUrl = import.meta.env.VITE_API_URL || "http://localhost:3001";
        
        // Fetch published events
        let events: any[] = [];
        try {
          const eventsRes = await fetch(`${apiUrl}/api/v1/events?per_page=1000`);
          if (eventsRes.ok) {
            const eventsData = await eventsRes.json();
            events = eventsData.events || [];
          }
        } catch (e) {
          console.error("Failed to fetch events for sitemap:", e);
        }

        // Fetch organizers
        let organizers: any[] = [];
        try {
          // Since there's no public organizers list endpoint, we'll extract unique organizations from events
          const uniqueOrgs = new Map();
          events.forEach((event: any) => {
            if (event.organization?.slug && !uniqueOrgs.has(event.organization.slug)) {
              uniqueOrgs.set(event.organization.slug, {
                slug: event.organization.slug,
                updated_at: event.updated_at,
              });
            }
          });
          organizers = Array.from(uniqueOrgs.values());
        } catch (e) {
          console.error("Failed to extract organizers for sitemap:", e);
        }

        const entries: SitemapEntry[] = [
          { path: "/", changefreq: "daily", priority: "1.0" },
          { path: "/events", changefreq: "daily", priority: "0.9" },
          ...events.map((event: any) => ({
            path: `/events/${event.id}`,
            changefreq: "daily" as const,
            priority: "0.8",
            lastmod: event.updated_at,
          })),
          ...organizers.map((org: any) => ({
            path: `/organizers/${org.slug}`,
            changefreq: "weekly" as const,
            priority: "0.7",
            lastmod: org.updated_at,
          })),
        ];

        const urls = entries.map((e) =>
          [
            `  <url>`,
            `    <loc>${BASE_URL}${e.path}</loc>`,
            e.changefreq ? `    <changefreq>${e.changefreq}</changefreq>` : null,
            e.priority ? `    <priority>${e.priority}</priority>` : null,
            e.lastmod ? `    <lastmod>${e.lastmod.split('T')[0]}</lastmod>` : null,
            `  </url>`,
          ]
            .filter(Boolean)
            .join("\n"),
        );

        const xml = [
          `<?xml version="1.0" encoding="UTF-8"?>`,
          `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
          ...urls,
          `</urlset>`,
        ].join("\n");

        return new Response(xml, {
          headers: {
            "Content-Type": "application/xml",
            "Cache-Control": "public, max-age=3600",
          },
        });
      },
    },
  },
});
