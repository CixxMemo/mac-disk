// Sahte DOM ile arayüz betiğini çalıştırır. Tarayıcı açmaz, dosya sistemine dokunmaz.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const webDir = path.join(__dirname, '..', '..', 'Resources', 'web');

class Node {
  constructor(tag = 'div', document) {
    this.document = document;
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
  append(...items) { for (const item of items) { const node = typeof item === 'string' ? this.document.createTextNode(item) : item; node.parent = this; this.children.push(node); } }
  replaceChildren(...items) { this.children.forEach(n => { n.parent = null; }); this.children = []; this._text = ''; this.append(...items); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(n => n !== this); this.parent = null; }
  focus() { this.document.activeElement = this; }
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

/** Arayüzü yükler. `bridge` verilirse yerel (WebKit) kipi, verilmezse dosya kipini taklit eder. */
function boot({ bridge } = {}) {
  const html = fs.readFileSync(path.join(webDir, 'index.html'), 'utf8');
  const source = fs.readFileSync(path.join(webDir, 'app.js'), 'utf8');
  new vm.Script(source);
  let copiedText = '';
  const byId = new Map();
  const document = {
    body: null, activeElement: null, handlers: {},
    getElementById: id => { if (!byId.has(id)) throw new Error(`Missing DOM id: ${id}`); return byId.get(id); },
    createElement: tag => new Node(tag, document), createElementNS: (_, tag) => new Node(tag, document),
    createTextNode: text => { const node = new Node('#text', document); node.textContent = text; return node; },
    querySelectorAll: selector => document.body.querySelectorAll(selector),
    addEventListener: (event, handler) => { document.handlers[event] = handler; }, execCommand: () => true
  };
  document.body = new Node('body', document);
  document.activeElement = document.body;
  const markup = html.slice(0, html.indexOf('<script src="app.js">'));
  for (const match of markup.matchAll(/<([a-z][\w:-]*)([^<>]*?)>/gi)) {
    const node = new Node(match[1], document);
    for (const attr of match[2].matchAll(/([\w:-]+)(?:="([^"]*)")?/g)) node.setAttribute(attr[1], attr[2] ?? '');
    if (node.id) { if (byId.has(node.id)) throw new Error(`Duplicate id ${node.id}`); byId.set(node.id, node); }
    document.body.append(node);
  }
  const sandbox = {
    document, navigator: { clipboard: { writeText: async value => { copiedText = value; } } },
    ResizeObserver: class { observe() {} }, requestAnimationFrame: callback => callback(),
    setTimeout: () => 1, clearTimeout() {}, console
  };
  sandbox.window = sandbox;
  if (bridge) sandbox.webkit = { messageHandlers: { diskatlas: { postMessage: bridge } } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return {
    html, source, document, sandbox, byId,
    run: code => vm.runInContext(code, sandbox),
    get: id => document.getElementById(id),
    copied: () => copiedText,
    ready: () => sandbox.diskAtlasReady ?? Promise.resolve()
  };
}

const settle = async (times = 5) => { for (let i = 0; i < times; i++) await new Promise(resolve => setImmediate(resolve)); };

/** Sahte köprü: `handlers[type](payload)` değer döner veya hata fırlatır. Çağrılar `calls` içinde kaydedilir. */
function fakeBridge(handlers) {
  const calls = [];
  const post = async text => {
    const request = JSON.parse(text);
    calls.push({ type: request.type, payload: request.payload });
    try {
      const handler = handlers[request.type];
      if (!handler) throw new Error(`Bilinmeyen köprü işlemi: ${request.type}`);
      return JSON.stringify({ id: request.id, ok: true, data: await handler(request.payload) });
    } catch (error) {
      return JSON.stringify({ id: request.id, ok: false, error: error.message });
    }
  };
  post.calls = calls;
  return post;
}

/** Arayüzün doğrulayıcısından geçen en küçük geçerli rapor. */
function makeReport(overrides = {}) {
  const node = (name, p, bytes, category = 'personal', children) => ({ name, path: p, bytes, logical: bytes, category, ...(children ? { children } : {}) });
  const home = node('test', '/Users/test', 6e9, 'personal', [node('Library', '/Users/test/Library', 4e9), node('Documents', '/Users/test/Documents', 2e9)]);
  return {
    schema: 2, app: 'Disk Atlas', demo: false, created: '2026-10-19T09:00:00.000000+00:00', scope: '/',
    platform: 'darwin', incomplete: false, seconds: 3.2,
    disk: { total: 500e9, free: 100e9, used: 400e9 },
    tree: node('Data', '/', 10e9, 'personal', [node('Users', '/Users', 6e9, 'personal', [home]), node('System', '/System', 4e9, 'system')]),
    categories: { cache: 0, build: 0, dependencies: 0, models: 0, personal: 6e9, system: 4e9 },
    candidates: [],
    largest: [node('big.bin', '/Users/test/big.bin', 3e9)],
    stats: { entries: 100, files: 80, folders: 20, errors: 1, symlinks: 0, otherMounts: 0, cloudPlaceholders: 0, hardlinkRepeats: 0 },
    errors: [{ path: '/Users/test/Library/Mail', reason: 'PermissionError: Operation not permitted' }],
    measurement: { unit: 'bytes' },
    ...overrides
  };
}

/** Köprünün `loadScan` yanıtındaki `apps` bölümü (Swift AppsReport ile aynı biçim). */
function makeApps(overrides = {}) {
  const component = (id, name, bytes, paths, safety) => ({ id, name, bytes, paths, safety, category: 'dependencies', what: `${name} nedir`, why: `${name} neden bu türde`, ifRemoved: `${name} silinirse` });
  return {
    homePath: '/Users/test', recognizedBytes: 7e9,
    apps: [
      { id: 'android', name: 'Android', tone: 'android', bytes: 5e9, components: [
        component('android-sdk', 'Android SDK', 3e9, ['/Users/test/Library'], 'incele'),
        component('android-avd', 'Sanal cihazlar', 2e9, ['/Users/test/.android/avd'], 'güvenli')] },
      { id: 'js', name: 'JavaScript araçları', tone: 'dev', bytes: 2e9, components: [
        component('npm-cache', 'npm önbelleği', 2e9, ['/Users/test/.npm'], 'güvenli')] }
    ],
    unrecognized: [
      { path: '/Users/test/Library/Application Support/Foo', bytes: 1e9, ownBytes: 9e8 },
      { path: '/Users/test/Bar', bytes: 5e8, ownBytes: 5e8 }
    ],
    ...overrides
  };
}

module.exports = { boot, settle, fakeBridge, makeReport, makeApps, webDir };
