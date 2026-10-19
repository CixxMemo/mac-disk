// DOM-level interaction checks. This does not launch a browser or touch source data.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, 'Disk-Atlas.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1);
const source = scripts[0][1];
new vm.Script(source);
let document;
let copiedText = '';
class Node {
  constructor(tag = 'div') {
    this.tagName = tag.toLowerCase(); this.children = []; this.style = {}; this.attrs = {};
    this.dataset = {}; this.value = ''; this.className = ''; this.disabled = false; this._text = '';
  }
  get classList() {
    const tokens = () => new Set(this.className.split(/\s+/).filter(Boolean));
    return {
      contains: name => tokens().has(name),
      add: (...names) => { const set = tokens(); names.forEach(n => set.add(n)); this.className = [...set].join(' '); },
      remove: (...names) => { const set = tokens(); names.forEach(n => set.delete(n)); this.className = [...set].join(' '); },
      toggle: (name, force) => { const set = tokens(); const enabled = force ?? !set.has(name); enabled ? set.add(name) : set.delete(name); this.className = [...set].join(' '); return enabled; }
    };
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value);
    if (name === 'class') this.className = String(value);
    if (name === 'id') this.id = String(value);
    if (name === 'disabled') this.disabled = true;
    if (name.startsWith('data-')) this.dataset[name.slice(5)] = String(value);
  }
  removeAttribute(name) { delete this.attrs[name]; }
  append(...items) { for (const item of items) { const node = typeof item === 'string' ? document.createTextNode(item) : item; node.parent = this; this.children.push(node); } }
  replaceChildren(...items) { this.children.forEach(n => { n.parent = null; }); this.children = []; this._text = ''; this.append(...items); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(n => n !== this); this.parent = null; }
  focus() { document.activeElement = this; }
  select() {}
  click() { return this.onclick?.({ target: this }); }
  getBoundingClientRect() { return { width: 720, height: 460, x: 0, y: 0 }; }
  get textContent() { return this._text + this.children.map(n => n.textContent).join(''); }
  set textContent(value) { this.children = []; this._text = String(value); }
  querySelectorAll(selector) {
    const result = [];
    const matches = node => selector.split(',').some(raw => {
      const part = raw.trim();
      if (part.startsWith('.')) return node.classList.contains(part.slice(1));
      const tag = part.split(/[:\[]/)[0];
      return node.tagName === tag && (!part.includes(':not([disabled])') || !node.disabled) && (!part.includes('[href]') || node.attrs.href);
    });
    const walk = node => node.children.forEach(child => { if (matches(child)) result.push(child); walk(child); });
    walk(this); return result;
  }
}
const byId = new Map();
document = {
  body: new Node('body'), activeElement: null, handlers: {},
  getElementById: id => { assert(byId.has(id), `Missing DOM id: ${id}`); return byId.get(id); },
  createElement: tag => new Node(tag), createElementNS: (_, tag) => new Node(tag),
  createTextNode: text => { const node = new Node('#text'); node.textContent = text; return node; },
  querySelectorAll: selector => document.body.querySelectorAll(selector),
  addEventListener: (event, handler) => { document.handlers[event] = handler; }, execCommand: () => true
};
document.activeElement = document.body;
for (const match of html.slice(0, html.indexOf('<script>')).matchAll(/<([a-z][\w:-]*)([^<>]*?)>/gi)) {
  const node = new Node(match[1]);
  for (const attr of match[2].matchAll(/([\w:-]+)(?:="([^"]*)")?/g)) node.setAttribute(attr[1], attr[2] ?? '');
  if (node.id) { assert(!byId.has(node.id), `Duplicate id ${node.id}`); byId.set(node.id, node); }
  document.body.append(node);
}
const context = vm.createContext({
  document, navigator: { clipboard: { writeText: async value => { copiedText = value; } } },
  ResizeObserver: class { observe() {} }, requestAnimationFrame: callback => callback(),
  setTimeout: () => 1, clearTimeout() {}, console
});
vm.runInContext(source, context);
const run = code => vm.runInContext(code, context);
const get = id => byId.get(id);
const log = text => console.log('PASS:', text);

async function main() {
  assert(!get('dashboard').classList.contains('hidden'));
  assert(get('welcome').classList.contains('hidden'));
  assert(get('freeValue').textContent.includes('GiB'));
  assert.equal(run('current.path'), run('home.path'));
  assert(get('treemap').querySelectorAll('button').length > 20);
  assert.equal(get('filesBody').children.length, 150);
  assert(run('findings.some(x => x.name === "Android SDK")'));
  log('real snapshot boots directly, summaries and nested map render, 150 largest files available');

  get('categoriesBtn').click();
  assert.equal(run('mode'), 'categories');
  assert.equal(get('categoriesBtn').attrs['aria-pressed'], 'true');
  assert.equal(get('treemap').children.length, run('Object.values(data.categories).filter(x=>x>0).length'));
  get('foldersBtn').click();
  run('goTo(index.get(home.path + "/Library"))');
  assert(run('current.path.endsWith("/Library")'));
  get('upBtn').click(); assert.equal(run('current.path'), run('home.path'));
  run('goTo(data.tree)'); get('homeBtn').click(); assert.equal(run('current.path'), run('home.path'));
  log('folder/category switch, drill-down, up, home, and breadcrumbs');

  get('findingsSearch').value = 'Android'; get('findingsSearch').oninput();
  assert.equal(get('findingsCount').textContent, '2 öğe');
  const check = get('findingsList').querySelectorAll('input')[0];
  check.checked = true; check.onchange();
  assert.equal(run('selected.size'), 1);
  assert(!get('copySelection').disabled);
  await get('copySelection').click();
  assert(copiedText.includes('/Android/sdk'));
  assert(copiedText.includes('silme talimatı değildir'));
  get('clearSelection').click(); assert.equal(run('selected.size'), 0);
  assert(get('copySelection').disabled);
  get('findingsSearch').value = 'not-an-existing-app'; get('findingsSearch').oninput();
  assert(get('findingsList').textContent.includes('Eşleşen öğe yok'));
  get('findingsSearch').value = ''; get('findingsSearch').oninput();
  const union = run('uniqueSelection([{path:"/a",bytes:100},{path:"/a/b",bytes:40},{path:"/ab",bytes:25}])');
  assert.equal(union.length, 2); assert.equal(union.reduce((s,x)=>s+x.bytes,0), 125);
  log('finding search, checkbox selection, copy, clear, empty results, and ancestor de-duplication');

  run('showView("files")');
  get('fileSearch').value = 'rootfs.img'; get('fileSearch').oninput();
  assert.equal(get('filesBody').children.length, 1);
  assert(get('view-explorer').classList.contains('hidden'));
  get('filesBody').querySelectorAll('button')[0].click();
  assert(!get('dialogBackdrop').classList.contains('hidden'));
  assert.equal(get('dialogTitle').textContent, 'rootfs.img');
  assert(get('dialogBody').textContent.includes('mantıksal boyut'));
  document.handlers.keydown({ key: 'Escape' }); assert(get('dialogBackdrop').classList.contains('hidden'));
  run('showView("health")'); assert(get('healthSummary').textContent.includes('436'));
  assert.equal(get('healthMetrics').children.length, 8);
  get('helpBtn').click(); assert(get('dialogBody').textContent.includes('sunucuya gönderilmez'));
  get('closeDialog').click();
  log('file search, file detail dialog, Escape dismissal, health metrics, and help');

  for (const [width,height] of [[320,340],[720,460],[1200,580]]) {
    context.testWidth = width; context.testHeight = height;
    const layout = run('squarify(home.children,0,0,testWidth,testHeight)');
    const area = layout.reduce((s,r)=>s+r.w*r.h,0);
    assert(Math.abs(area-width*height) < .001);
    for (const rect of layout) {
      assert(Number.isFinite(rect.w) && rect.w > 0 && Number.isFinite(rect.h) && rect.h > 0);
      assert(rect.x >= -.001 && rect.y >= -.001);
      assert(rect.x+rect.w <= width+.001 && rect.y+rect.h <= height+.001);
    }
    for (let i=0;i<layout.length;i++) for (let j=i+1;j<layout.length;j++) {
      const a=layout[i],b=layout[j];
      assert(Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x)<.001 || Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y)<.001);
    }
  }
  assert.equal(run('squarify([{bytes:0}],0,0,100,100).length'), 0);
  log('treemap area conservation, non-overlap and bounds at mobile/tablet/desktop widths');

  const original = fs.readdirSync(path.join(__dirname,'reports')).filter(x=>/^disk-atlas-.*\.json$/.test(x)).sort().at(-1);
  const raw = fs.readFileSync(path.join(__dirname,'reports',original),'utf8');
  await get('fileInput').onchange({target:{files:[{size:Buffer.byteLength(raw),text:async()=>raw}],value:'test'}});
  assert(!get('message').textContent.includes('Rapor açılamadı'));
  assert(run('findings.some(x=>x.name === "Android SDK")'));
  assert.equal(run('activeView'),'explorer');
  const pathBefore = run('data.tree.path');
  await get('fileInput').onchange({target:{files:[{size:2,text:async()=>'{}'}],value:'test'}});
  assert(get('message').textContent.includes('Rapor açılamadı'));
  assert.equal(run('data.tree.path'),pathBefore);
  await get('fileInput').onchange({target:{files:[{size:41*1024**2,text:async()=>{throw Error('must not read oversized file')}}],value:'test'}});
  assert(get('message').textContent.includes('40 MiB'));
  log('full original report import, derived findings, invalid-report preservation and import size limit');

  assert(html.includes("connect-src 'none'"));
  assert(!/\b(fetch\s*\(|XMLHttpRequest|WebSocket)/.test(source));
  assert(!/\b(innerHTML|eval)\s*\(/.test(source));
  log('network-disabled CSP, no network APIs, text-only report insertion');
  console.log('DOM checks complete. Real-browser layout/screenshot verification was not performed.');
}
main().catch(error=>{ console.error(error); process.exitCode=1; });
