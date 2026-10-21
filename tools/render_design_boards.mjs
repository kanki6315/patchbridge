#!/usr/bin/env node
// Renders design-canvas boards (.dc.html) to standalone HTML and PNG.
// Usage: node tools/render_design_boards.mjs <canvas project dir> <output dir> [page id]
// The project dir holds canvas.json; boards on every page except "components" are rendered.
// With a page id (poc, ipad, mac, live, tuner, switching, presets, concepts), only that page is rendered and its manifest entries replaced.
// Requires Google Chrome for PNGs; HTML snapshots need nothing.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const [srcDir, outDir, onlyPage] = process.argv.slice(2);
if (!srcDir || !outDir) { console.error('usage: render_design_boards.mjs <project dir> <out dir>'); process.exit(2); }
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const VOID = new Set(['meta', 'link', 'br', 'img', 'input', 'hr', 'source']);
const UNITLESS = new Set(['opacity', 'zIndex', 'fontWeight', 'flex', 'flexGrow', 'flexShrink', 'order', 'lineHeight']);

function parse(html) {
  const root = { tag: '#root', attrs: [], children: [] };
  const stack = [root];
  const re = /<!--[\s\S]*?-->|<\/([\w-]+)\s*>|<([\w-]+)((?:\s+[\w:@.-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>|([^<]+)/g;
  let m;
  while ((m = re.exec(html))) {
    const top = stack[stack.length - 1];
    if (m[0].startsWith('<!--')) continue;
    if (m[1]) {
      const i = stack.map((n) => n.tag).lastIndexOf(m[1].toLowerCase());
      if (i > 0) stack.length = i;
    } else if (m[2]) {
      const tag = m[2].toLowerCase();
      const attrs = [];
      const ar = /([\w:@.-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
      let a;
      while ((a = ar.exec(m[3] || ''))) attrs.push([a[1], a[2] ?? a[3] ?? a[4] ?? '']);
      const node = { tag, attrs, children: [] };
      top.children.push(node);
      if (!VOID.has(tag) && !m[4]) stack.push(node);
    } else if (m[5]) top.children.push({ text: m[5] });
  }
  return root;
}

const get = (scope, p) => p.trim().split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
const lit = (p, scope) => (p.trim() === 'true' ? true : p.trim() === 'false' ? false : get(scope, p));
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const escAttr = (s) => esc(s).replace(/"/g, '&quot;');
const kebab = (k) => (k.startsWith('Webkit') ? '-webkit' + k.slice(6) : k).replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
const cssOf = (o) => Object.entries(o).filter(([, v]) => v != null && v !== false)
  .map(([k, v]) => kebab(k) + ': ' + (typeof v === 'number' && !UNITLESS.has(k) ? v + 'px' : v)).join('; ');

function attrValue(raw, scope) {
  const whole = raw.match(/^\s*\{\{\s*([^}]+?)\s*\}\}\s*$/);
  if (whole) return lit(whole[1], scope);
  return raw.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_, p) => { const v = lit(p, scope); return v == null ? '' : String(v); });
}

const cache = new Map();
function loadBoard(file) {
  if (cache.has(file)) return cache.get(file);
  const s = fs.readFileSync(file, 'utf8');
  const tpl = s.split('<x-dc>')[1].split('</x-dc>')[0];
  const helmet = (tpl.match(/<helmet>([\s\S]*?)<\/helmet>/) || [, ''])[1];
  const body = tpl.replace(/<helmet>[\s\S]*?<\/helmet>/, '');
  const sm = s.match(/<script type="text\/x-dc" data-dc-script data-props='([^']*)'>([\s\S]*?)<\/script>/);
  const decl = JSON.parse(sm[1].replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
  const Component = new Function('DCLogic', sm[2] + '\nreturn Component;')(class { constructor() { this.props = {}; this.state = {}; } setState() {} });
  const b = { file, helmet, tree: parse(body), decl, Component };
  cache.set(file, b);
  return b;
}

function renderBoard(b, props) {
  const defaults = {};
  for (const [k, v] of Object.entries(b.decl)) if (!k.startsWith('$') && v && 'default' in v) defaults[k] = v.default;
  const c = new b.Component();
  c.props = { ...defaults, ...props };
  return renderNodes(b.tree.children, c.renderVals(), path.dirname(b.file));
}

function renderNodes(nodes, scope, dir) { return nodes.map((n) => renderNode(n, scope, dir)).join(''); }

function renderNode(n, scope, dir) {
  if (n.text != null) return n.text.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_, p) => { const v = lit(p, scope); return v == null ? '' : esc(v); });
  const A = Object.fromEntries(n.attrs);
  if (n.tag === 'sc-if') return attrValue(A.value, scope) ? renderNodes(n.children, scope, dir) : '';
  if (n.tag === 'sc-for') {
    const list = attrValue(A.list, scope) || [];
    return list.map((item, i) => renderNodes(n.children, { ...scope, [A.as]: item, $index: i }, dir)).join('');
  }
  if (n.tag === 'dc-import') {
    const props = {};
    for (const [k, raw] of n.attrs) if (k !== 'name' && !k.startsWith('hint-')) props[k.replace(/-(\w)/g, (_, ch) => ch.toUpperCase())] = attrValue(raw, scope);
    return renderBoard(loadBoard(path.join(dir, A.name + '.dc.html')), props);
  }
  let out = '<' + n.tag;
  for (const [k, raw] of n.attrs) {
    if (/^on[A-Z]/.test(k) || k.startsWith('hint-')) continue;
    let v = attrValue(raw, scope);
    if (k === 'style' && v && typeof v === 'object') v = cssOf(v);
    if (v === false || v == null) continue;
    out += ' ' + (k === 'classname' ? 'class' : k) + '="' + escAttr(v === true ? '' : v) + '"';
  }
  if (VOID.has(n.tag)) return out + '>';
  return out + '>' + renderNodes(n.children, scope, dir) + '</' + n.tag + '>';
}

function collectHelmets(b, seen = new Set()) {
  if (seen.has(b.file)) return '';
  seen.add(b.file);
  let h = b.helmet;
  for (const m of fs.readFileSync(b.file, 'utf8').matchAll(/<dc-import name="([\w-]+)"/g)) h += collectHelmets(loadBoard(path.join(path.dirname(b.file), m[1] + '.dc.html')), seen);
  return h;
}

const canvas = JSON.parse(fs.readFileSync(path.join(srcDir, 'canvas.json'), 'utf8'));
const pageName = Object.fromEntries((canvas.pages || []).map((p) => [p.id, p.name]));
const firstPage = canvas.pages?.[0]?.id;
const manifest = [];
for (const key of canvas.order) {
  const entry = canvas.boards[key];
  const page = entry.page || firstPage;
  if (page === 'components' || (onlyPage && page !== onlyPage)) continue;
  const b = loadBoard(path.join(srcDir, key));
  const { w, h } = entry;
  // Scene switching and preset browser boards span devices, so their slugs keep the device folder.
  const slug = (page === 'switching' || page === 'presets' ? key : key.replace(/^(poc|ipad|mac|live)\//, '')).replace(/\.dc\.html$/, '').replace(/[^\w-]+/g, '-');
  const sub = page === 'concepts' ? 'concepts' : page === 'ipad' ? 'ipad' : page === 'mac' ? 'mac' : page === 'live' ? 'live' : page === 'tuner' ? 'tuner' : page === 'switching' ? 'switching' : page === 'presets' ? 'presets' : 'screens';
  // Mac windows and popovers have rounded corners, so they render on a transparent page.
  const clear = sub === 'mac' || /^live\/mac-/.test(key);
  const bg = clear ? 'transparent' : '#000';
  fs.mkdirSync(path.join(outDir, 'html', sub), { recursive: true });
  fs.mkdirSync(path.join(outDir, sub), { recursive: true });
  const html = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=' + w + '">\n<title>' + esc(entry.title || slug) + '</title>\n'
    + collectHelmets(b) + '\n<style>html,body{margin:0;width:' + w + 'px;height:' + h + 'px;overflow:hidden;background:' + bg + '}</style>\n</head>\n<body>\n'
    + renderBoard(b, {}) + '\n</body>\n</html>\n';
  const htmlPath = path.join(outDir, 'html', sub, slug + '.html');
  fs.writeFileSync(htmlPath, html);
  const pngPath = path.join(outDir, sub, slug + '.png');
  if (fs.existsSync(CHROME)) {
    const args = ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
      '--virtual-time-budget=4000', ...(clear ? ['--default-background-color=00000000'] : []), '--window-size=' + w + ',' + h, '--screenshot=' + path.resolve(pngPath), 'file://' + path.resolve(htmlPath)];
    // Headless Chrome occasionally exits early on macOS; one retry is enough in practice.
    try { execFileSync(CHROME, args, { stdio: 'ignore' }); } catch { execFileSync(CHROME, args, { stdio: 'ignore' }); }
  }
  manifest.push({ key, slug, page: pageName[page] || page, title: entry.title, w, h, png: path.relative(outDir, pngPath), html: path.relative(outDir, htmlPath) });
  console.log('rendered', sub + '/' + slug);
}
const manifestPath = path.join(outDir, 'manifest.json');
const kept = onlyPage && fs.existsSync(manifestPath)
  ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')).filter((m) => m.page !== (pageName[onlyPage] || onlyPage)) : [];
fs.writeFileSync(manifestPath, JSON.stringify([...kept, ...manifest], null, 2) + '\n');
