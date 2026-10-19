// DOM-level interaction checks against Resources/web using the shared fake-DOM harness.
// This does not launch a browser or touch source data. It needs a real scan report in reports/
// (git-ignored); without one the real-data checks are skipped.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { boot } = require('./Tests/web/harness.cjs');

const reports = path.join(__dirname, 'reports');
const names = fs.existsSync(reports) ? fs.readdirSync(reports).filter(x => /^disk-atlas-.*\.json$/.test(x)).sort() : [];
if (!names.length) { console.log('SKIPPED: reports/ altında gerçek rapor yok.'); process.exit(0); }
const original = names.at(-1);
const raw = fs.readFileSync(path.join(reports, original), 'utf8');

const env = boot();
const { html, source, document, sandbox: context } = env;
const { run, get } = env;
const log = text => console.log('PASS:', text);
// Eski gömülü açılışın yerine: gerçek raporu dosya kipinde yükle.
run(`load(${raw})`);
Object.defineProperty(global, 'copiedText', { get: () => env.copied() });

async function main() {
  assert(!get('dashboard').classList.contains('hidden'));
  assert(get('welcome').classList.contains('hidden'));
  assert(get('freeValue').textContent.includes('GB'));
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

  await get('fileInput').onchange({target:{files:[{size:Buffer.byteLength(raw),text:async()=>raw}],value:'test'}});
  assert(!get('message').textContent.includes('Rapor açılamadı'));
  assert(run('findings.some(x=>x.name === "Android SDK")'));
  assert.equal(run('activeView'),'explorer');
  const pathBefore = run('data.tree.path');
  await get('fileInput').onchange({target:{files:[{size:2,text:async()=>'{}'}],value:'test'}});
  assert(get('message').textContent.includes('Rapor açılamadı'));
  assert.equal(run('data.tree.path'),pathBefore);
  await get('fileInput').onchange({target:{files:[{size:41*1024**2,text:async()=>{throw Error('must not read oversized file')}}],value:'test'}});
  assert(get('message').textContent.includes('40 MB'));
  log('full original report import, derived findings, invalid-report preservation and import size limit');

  assert(html.includes("connect-src 'none'"));
  assert(!/\b(fetch\s*\(|XMLHttpRequest|WebSocket)/.test(source));
  assert(!/\b(innerHTML|eval)\s*\(/.test(source));
  log('network-disabled CSP, no network APIs, text-only report insertion');
  console.log('DOM checks complete. Real-browser layout/screenshot verification was not performed.');
}
main().catch(error=>{ console.error(error); process.exitCode=1; });
