// @ts-check
import { defineConfig } from 'astro/config';

// Static output, served by Cloudflare Workers static assets (see wrangler.jsonc).
export default defineConfig({
  // TODO: set to the real domain once it exists (used for canonical and OG URLs).
  site: 'https://patchbridge.example.com',
  output: 'static',
  trailingSlash: 'ignore',
  build: { format: 'directory' },
});
