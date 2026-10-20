# Patchbridge site

The marketing site, plus the support and privacy pages App Store Connect asks for. It's built with Astro as a static site and served by Cloudflare Workers static assets (free plan).

| Page | Source | App Store Connect field |
|---|---|---|
| `/` | `src/pages/index.astro` | Marketing URL |
| `/support` | `src/pages/support.md` | Support URL |
| `/privacy` | `src/pages/privacy.md` | Privacy Policy URL |

## Editing

- **Copy:** the home page text is inline in `src/pages/index.astro`. Support and privacy are plain Markdown.
- **Links and contact:** `src/site.ts`. An empty store URL shows a "coming soon" tag instead of a dead link.
- **Domain:** `patchbridge.arjunakankipati.com`. It's set in two places: `site` in `astro.config.mjs` (canonical and Open Graph URLs) and the custom-domain route in `wrangler.jsonc`.
- **Look:** tokens in `src/styles/global.css` mirror the app's Stage theme in `../DESIGN.md`. Screens in `src/assets/screens/` are copies of the design boards in `../docs/design/`.
- **Social image:** `public/og.png` is built from those screens. Run `node ../tools/render_og_image.mjs` after changing them (needs Google Chrome).

## Run and deploy

```sh
npm install
npm run dev       # http://localhost:4321
npm run deploy    # astro build && wrangler deploy
```

The first deploy asks you to log in with `npx wrangler login`. Deploying attaches `patchbridge.arjunakankipati.com` to the `patchbridge-site` Worker and creates its DNS record. That needs `arjunakankipati.com` to be a zone in the same Cloudflare account.
