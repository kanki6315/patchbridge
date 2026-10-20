#!/usr/bin/env node
// Renders the site's social preview image (site/public/og.png, 1200x630)
// from the iPhone portrait, iPhone landscape and iPad screens in site/src/assets/screens.
// Usage: node tools/render_og_image.mjs
// Requires Google Chrome.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const screens = path.join(root, 'site/src/assets/screens');
const font = path.join(root, 'site/node_modules/@fontsource-variable/archivo/files/archivo-latin-wght-normal.woff2');
const out = path.join(root, 'site/public/og.png');
const badges = path.join(root, 'site/src/assets/badges');
const url = (f) => 'file://' + f;

// The Patch Cable "pb" mark, as in site/src/components/Logo.astro.
const logo = `<svg width="54" height="45" viewBox="0 0 300 250"><g fill="currentColor">
  <path fill-rule="evenodd" d="M5 182V123C5 90 24 74 57 74H108C133 74 147 88 147 113V132C147 139 152 139 159 141L168 144Q174 146 174 138V70H203V77H249C278 77 294 92 294 119V139C294 167 278 183 250 183H204C186 183 174 177 161 165L155 160Q149 155 142 158C134 175 120 183 100 183H54C35 183 35 155 54 155H100C112 155 119 148 119 137V116C119 108 114 104 105 104H57C42 104 35 111 35 124V182ZM203 105V149Q203 155 210 155H249C259 155 265 149 265 139V120C265 110 260 105 249 105Z"/>
  <rect x="1" y="181" width="37" height="26" rx="3"/>
  <path d="M10 211H29V227H10Z M13 231H26L30 237Q30 241 25 245Q20 249 15 245L9 240Q7 236 13 231Z"/>
  <rect x="169" y="45" width="38" height="27" rx="3"/>
  <path d="M179 21H198V41H179Z M181 1H194L199 7Q200 11 196 14V17H180V14Q175 11 178 7Z"/>
</g></svg>`;

const html = `<!doctype html><meta charset="utf-8"><style>
@font-face { font-family: Archivo; src: url(${url(font)}) format('woff2'); font-weight: 100 900; }
* { margin: 0; box-sizing: border-box; }
html, body { width: 1200px; height: 630px; overflow: hidden; }
body {
  position: relative; color: #f2f2ee;
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif;
  background: radial-gradient(ellipse 70% 80% at 72% 40%, #1d2410 0%, #0d0e0a 70%);
}
.brand { position: absolute; left: 60px; top: 58px; width: 400px; }
.badges { display: flex; gap: 12px; margin-top: 26px; }
.badges img { display: block; height: 42px; width: auto; }
.mark { color: #d1e14a; }
h1 { margin-top: 22px; font: 800 62px/1 Archivo, 'Arial Black', sans-serif; font-stretch: 125%; letter-spacing: -0.01em; }
p { margin-top: 16px; font-size: 25px; line-height: 1.3; color: #b1b2ab; }
.device {
  position: absolute; background: #050504; border: 1.5px solid #3a3a34;
  box-shadow: inset 0 1px 0 rgb(255 255 255 / 0.14), 0 30px 70px rgb(0 0 0 / 0.6);
}
.device img { display: block; width: 100%; height: 100%; }
.ipad { left: 474px; top: 46px; width: 680px; padding: 14px; border-radius: 34px; }
.ipad img { height: auto; border-radius: 21px; }
.phone { left: 250px; top: 340px; width: 222px; padding: 8px; border-radius: 40px; }
.phone img { height: auto; border-radius: 32px; }
.wide { left: 640px; top: 400px; width: 520px; padding: 7px; border-radius: 30px; }
.wide img { height: auto; border-radius: 23px; }
</style>
<div class="brand">
  <div class="mark">${logo}</div>
  <h1>Patchbridge</h1>
  <p>Your tone in your hands</p>
  <div class="badges"><img src="${url(path.join(badges, 'app-store.svg'))}"><img src="${url(path.join(badges, 'mac-app-store.svg'))}"></div>
</div>
<div class="device ipad"><img src="${url(path.join(screens, 'ipad-overview.png'))}"></div>
<div class="device phone"><img src="${url(path.join(screens, 'phone-overview.png'))}"></div>
<div class="device wide"><img src="${url(path.join(screens, 'phone-landscape.png'))}"></div>
`;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'og-'));
const page = path.join(tmp, 'og.html');
fs.writeFileSync(page, html);
execFileSync(CHROME, ['--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
  '--allow-file-access-from-files', '--user-data-dir=' + path.join(tmp, 'profile'), '--window-size=1200,630', '--screenshot=' + out, url(page)], { stdio: 'ignore' });
fs.rmSync(tmp, { recursive: true });
console.log('wrote ' + path.relative(root, out));
