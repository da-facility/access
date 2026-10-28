import { createRootRoute, HeadContent, Link, Outlet, Scripts } from "@tanstack/react-router";
import { InternationalizationProvider } from "@astryxdesign/core/i18n";
import { LinkProvider } from "@astryxdesign/core/Link";
import { Theme } from "@astryxdesign/core/theme";
import { neutralTheme } from "@astryxdesign/theme-neutral/built";
import en from "@da-facility/ui/locales/en.json";
import type { AnchorHTMLAttributes } from "react";
import "@astryxdesign/core/reset.css";
import "@astryxdesign/core/astryx.css";
import "@astryxdesign/theme-neutral/theme.css";
import "@da-facility/ui/style.css";
import "../styles.css";

/** Routes Astryx links through TanStack Router so navigation stays client-side. */
function RouterLink({ href, ...props }: AnchorHTMLAttributes<HTMLAnchorElement>) {
  if (!href || /^[a-z]+:/i.test(href) || href.startsWith("/api/") || href.startsWith("/admin/auth/")) return <a href={href} {...props} />;
  return <Link to={href} {...props} />;
}

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "darkreader-lock", content: "true" },
      { name: "color-scheme", content: "light dark" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "RustDesk · Da Facility" },
    ],
  }),
  component: Root,
});

function Root() {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        <Theme theme={neutralTheme} mode="system">
          <InternationalizationProvider locale="en" messages={{ en }}>
            <LinkProvider component={RouterLink}>
              <Outlet />
            </LinkProvider>
          </InternationalizationProvider>
        </Theme>
        <Scripts />
      </body>
    </html>
  );
}
