import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";

export function SiteFooter() {
  const { t } = useTranslation();

  return (
    <footer className="border-t border-border/60 bg-background/80 backdrop-blur-xl">
      <div className="mx-auto max-w-6xl px-5 py-8">
        <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          <div className="flex items-center gap-2">
            <span className="font-display text-lg font-bold">Rally</span>
            <span className="text-sm text-muted-foreground">
              © {new Date().getFullYear()} Rally
            </span>
          </div>

          <nav className="flex flex-wrap gap-4 text-sm text-muted-foreground">
            <Link to="/terms" className="hover:text-foreground transition-colors">
              {t("legal.termsTitle")}
            </Link>
            <Link to="/privacy" className="hover:text-foreground transition-colors">
              {t("legal.privacyTitle")}
            </Link>
          </nav>
        </div>
      </div>
    </footer>
  );
}
