#!/usr/bin/env node
// Marketing composition matched to tools/render_og_image.mjs and site/public/og.png.
// Native views are captured separately; this never draws or edits the app UI.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.resolve(process.argv[2] || path.join(root, 'output/mac-screenshots'));
const video = process.argv.includes('--video');
const clipBackground = process.argv.includes('--clip-background');
const destination = video ? path.join(output, clipBackground ? 'video-backgrounds' : 'video-frames') : output;
fs.mkdirSync(destination, { recursive: true });
const font = path.join(root, 'site/node_modules/@fontsource-variable/archivo/files/archivo-latin-wght-normal.woff2');
if (!fs.existsSync(font)) throw new Error('Install the site font first: npm ci --ignore-scripts --prefix site');
const fontData = fs.readFileSync(font).toString('base64');
const logoSource = fs.readFileSync(path.join(root, 'docs/design/brand/patch-cable.svg'), 'utf8');
const logo = logoSource.replace('width="1024" height="1024" viewBox="0 0 1024 1024"', 'width="112" height="94" viewBox="0 0 300 250"')
    .replace('transform="translate(143 202) scale(2.5)" ', '');
const escape = s => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const stories = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'), 'utf8'));
const layouts = path.join(destination, 'layouts'); fs.mkdirSync(layouts, { recursive: true });
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'patchbridge-previews-'));
try {
    for (const story of stories) {
        const native = fs.readFileSync(path.join(output, 'native', story.file + '.png')).toString('base64');
        let html = `<!doctype html><html lang="en"><meta charset="utf-8"><title>${escape(story.title.replaceAll('\n', ' '))}</title>
<style>
@font-face { font-family: Archivo; src: url(data:font/woff2;base64,${fontData}) format('woff2'); font-weight: 100 900; }
* { box-sizing: border-box; margin: 0; }
html, body { width: 2880px; height: 1800px; overflow: hidden; }
body { position: relative; color: #f2f2ee; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
 background: radial-gradient(ellipse 70% 80% at 72% 40%, #1d2410 0%, #0d0e0a 70%); }
.brand { position: absolute; left: 144px; top: 150px; }
.brand svg { display: block; }
.wordmark { margin-top: 40px; font: 800 130px/1 Archivo, sans-serif; letter-spacing: -0.01em; }
.tagline { margin-top: 24px; font-size: 46px; line-height: 1.3; color: #b1b2ab; }
.story { position: absolute; left: 144px; top: 790px; width: 1200px; }
h1 { font: 800 100px/1.04 Archivo, sans-serif; letter-spacing: -0.01em; white-space: pre-line; }
.description { margin-top: 48px; font-size: 44px; line-height: 1.4; color: #b1b2ab; white-space: pre-line; }
.platform { position: absolute; bottom: 150px; left: 144px; font-size: 36px; color: #b1b2ab; }
.window { position: absolute; left: 1470px; top: 34px; width: 1140px; border-radius: 24px; overflow: hidden;
 background: #050504; border: 1.5px solid #3a3a34;
 box-shadow: inset 0 1px 0 rgb(255 255 255 / 0.14), 0 30px 70px rgb(0 0 0 / 0.6); }
.window img { display: block; width: 100%; height: auto; }
</style>
<div class="brand">${logo}<div class="wordmark">Patchbridge</div><p class="tagline">Your tone in your hands</p></div>
<main class="story"><h1>${escape(story.title)}</h1><p class="description">${escape(story.subtitle)}</p></main>
<div class="platform">For Mac</div>
<div class="window"><img src="data:image/png;base64,${native}" alt="Patchbridge native Mac window showing ${escape(story.title.replaceAll('\n', ' '))}"></div>
</html>`;
        if (video) html = html.replace('</style>', `
/* Recompose at 16:9; do not crop or stretch the approved 16:10 screenshots. */
html, body { width: 1920px; height: 1080px; }
.brand { left: 96px; top: 90px; }
.brand svg { width: 78px; height: 65px; }
.wordmark { font-size: 86px; margin-top: 26px; }
.tagline { font-size: 30px; margin-top: 16px; }
.story { left: 96px; top: 475px; width: 900px; }
h1 { font-size: 64px; }
.description { font-size: 28px; margin-top: 30px; }
.platform { left: 96px; bottom: 90px; font-size: 24px; }
.window { left: 1150px; top: 34px; width: 660px; border-radius: 16px; }
</style>`);
        if (clipBackground) html = html.replace('</style>', '.window img { visibility: hidden; }</style>');
        const file = path.join(layouts, story.file + '.html'); fs.writeFileSync(file, html);
        execFileSync('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
            '--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
            '--allow-file-access-from-files', '--user-data-dir=' + path.join(temp, 'profile'),
            video ? '--window-size=1920,1080' : '--window-size=2880,1800', '--virtual-time-budget=1000',
            '--screenshot=' + path.join(destination, story.file + '.png'), 'file://' + file
        ], { stdio: 'pipe' });
        console.log('Composed ' + story.file);
    }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
