#!/usr/bin/env node
// Writes the iPad PoC board wrappers (docs/design/source/ipad/*.dc.html) and their canvas.json entries.
// Each board is a thin wrapper that imports Workspace or Connect with fixed props.
// Usage: node tools/ipad_boards.mjs [canvas project dir]   (default docs/design/source)
import fs from 'node:fs';
import path from 'node:path';

const srcDir = process.argv[2] || 'docs/design/source';
const L = [1180, 820], P = [820, 1180];

// [slug, title, component, props, size]. Rows are canvas rows; slugs match the iPhone board they stand in for.
const ROWS = [
  [
    ['c-welcome', 'Welcome', 'Connect', { step: 'welcome' }, L],
    ['c-getmac', 'Get the Mac app', 'Connect', { step: 'getMac' }, L],
    ['c-linksent', 'Link sent to Mac', 'Connect', { step: 'linkSent' }, L],
    ['c-found', 'Choose your Mac', 'Connect', { step: 'found' }, L],
    ['c-approve', 'Approve on Mac', 'Connect', { step: 'approve' }, L],
    ['c-loading', 'Loading the QC', 'Connect', { step: 'loading' }, L],
    ['c-lost', 'Error: connection ended', 'Connect', { step: 'lost' }, L],
    ['c-timeout', 'Error: no reply', 'Connect', { step: 'timeout' }, L],
    ['c-bluetooth', 'Error: Bluetooth off', 'Connect', { step: 'bluetooth' }, L]
  ],
  [
    ['o-overview', 'Overview · Opto Comp', 'Workspace', {}, L],
    ['o-row3', 'Overview · row 3 block', 'Workspace', { 'block-key': 'chorus', 'hero-index': '0' }, L],
    ['o-demo', 'Overview · demo mode', 'Workspace', { demo: true }, L],
    ['o-save', 'Save confirmation', 'Workspace', { overlay: 'saveSheet' }, L],
    ['o-saving', 'Saving', 'Workspace', { overlay: 'saving' }, L],
    ['o-saved', 'Saved', 'Workspace', { overlay: 'saved' }, L],
    ['o-changed', 'Changed on the QC', 'Workspace', { overlay: 'deviceChange' }, L],
    ['o-details', 'Connection details', 'Workspace', { overlay: 'details' }, L],
    ['t-appearance', 'Appearance', 'Workspace', { overlay: 'appearance' }, L]
  ],
  [
    ['e-fine', 'Editor · fine steps (hold, slide out)', 'Workspace', { state: 'fine' }, L],
    ['e-pending', 'Editor · sending', 'Workspace', { state: 'pending' }, L],
    ['e-confirmed', 'Editor · confirmed', 'Workspace', { state: 'confirmed' }, L],
    ['e-adjusted', 'Editor · adjusted by the QC', 'Workspace', { state: 'adjusted' }, L],
    ['e-rejected', 'Editor · not applied', 'Workspace', { state: 'rejected' }, L],
    ['e-typing', 'Editor · typing', 'Workspace', { state: 'typing' }, L],
    ['e-invalid', 'Editor · out of range', 'Workspace', { state: 'typingInvalid' }, L],
    ['e-capture', 'Editor · read-only capture', 'Workspace', { 'block-key': 'capture' }, L],
    ['e-chorus', 'Editor · option parameter', 'Workspace', { 'block-key': 'chorus' }, L]
  ],
  [
    ['p-overview', 'Portrait · overview', 'Workspace', { orientation: 'portrait' }, P],
    ['p-pending', 'Portrait · sending', 'Workspace', { orientation: 'portrait', state: 'pending' }, P],
    ['p-typing', 'Portrait · typing', 'Workspace', { orientation: 'portrait', state: 'typing' }, P]
  ]
];

const attr = (v) => (v === true ? '{{true}}' : String(v));
const canvasPath = path.join(srcDir, 'canvas.json');
const canvas = JSON.parse(fs.readFileSync(canvasPath, 'utf8'));
if (!canvas.pages.some((p) => p.id === 'ipad')) canvas.pages.splice(1, 0, { id: 'ipad', name: 'iPad PoC' });
for (const k of Object.keys(canvas.boards)) if (k.startsWith('ipad/') && !/[A-Z]/.test(path.basename(k)[0])) delete canvas.boards[k];
canvas.order = canvas.order.filter((k) => !k.startsWith('ipad/') || canvas.boards[k]);

const TITLES = [
  'Connect: a centred column, same steps as iPhone',
  'Overview: grid, row list and editor on one screen; popovers for save and connection',
  'Editor panel: every edit state, number pad as a popover',
  'Portrait: grid on top, row list beside the editor'
];
const COMPONENTS = [['Workspace', 'Workspace (Tweaks: orientation, block, state, overlay)', L], ['Connect', 'Connect (Tweaks: step)', L]];
let cx = 0;
for (const [name, title, [w, h]] of COMPONENTS) {
  const key = 'ipad/' + name + '.dc.html';
  canvas.boards[key] = { x: cx, y: 1200, w, h, title, page: 'components' };
  if (!canvas.order.includes(key)) canvas.order.push(key);
  cx += w + 120;
}

let y = 0;
for (const [ri, row] of ROWS.entries()) {
  canvas.notes['ipad' + ri] = { x: 0, y: y - 280, text: TITLES[ri], kind: 'title1', maxW: 4000, page: 'ipad' };
  let x = 0, rowH = 0;
  for (const [slug, title, comp, props, [w, h]] of row) {
    const key = 'ipad/' + slug + '.dc.html';
    const attrs = Object.entries(props).map(([k, v]) => ' ' + k + '="' + attr(v) + '"').join('');
    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>iPad · ${title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;display=swap" rel="stylesheet">
<style>body{margin:0}</style>
</helmet>
<dc-import name="${comp}"${attrs} hint-size="${w}px,${h}px"></dc-import>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":${w},"height":${h}}}'>
class Component extends DCLogic {
  renderVals() { return {}; }
}
</script>
</body>
</html>
`;
    fs.writeFileSync(path.join(srcDir, key), html);
    canvas.boards[key] = { x, y, w, h, title, page: 'ipad' };
    if (!canvas.order.includes(key)) canvas.order.push(key);
    x += w + 120;
    rowH = Math.max(rowH, h);
  }
  y += rowH + 240;
}
fs.writeFileSync(canvasPath, JSON.stringify(canvas, null, 2) + '\n');
console.log('wrote', ROWS.flat().length, 'iPad boards');
