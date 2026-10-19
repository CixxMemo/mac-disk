const { test } = require('node:test');
const assert = require('node:assert/strict');
const { boot, settle, fakeBridge, makeReport } = require('./harness.cjs');

const visible = (env, id) => !env.get(id).classList.contains('hidden');
const nativeEnv = async handlers => {
  const bridge = fakeBridge({ permissionStatus: () => ({ status: 'granted' }), listScans: () => [], appInfo: () => ({ version: '0.2.0', macOS: '15.7' }), ...handlers });
  const env = boot({ bridge });
  await env.ready(); await settle();
  return { env, bridge };
};

test('native boot shows the welcome screen and permission card when there are no scans', async () => {
  const { env, bridge } = await nativeEnv();
  assert(visible(env, 'welcome') && visible(env, 'welcomeNative') && !visible(env, 'welcomeFile'));
  assert(visible(env, 'scanBtn'));
  assert(env.get('permissionTitle').textContent.includes('Tam Disk Erişimi'));
  assert(!visible(env, 'openSettingsBtn'));
  assert(!visible(env, 'dashboard'));
  assert(env.get('appInfoText').textContent.includes('0.2.0') && env.get('appInfoText').textContent.includes('15.7'));
  assert.deepEqual(bridge.calls.map(c => c.type).sort(), ['appInfo', 'listScans', 'permissionStatus']);
});

test('native boot opens the newest saved scan', async () => {
  const { env, bridge } = await nativeEnv({ listScans: () => [{ id: 'scan-2' }, { id: 'scan-1' }], loadScan: () => makeReport() });
  assert.deepEqual(bridge.calls.find(c => c.type === 'loadScan').payload, { id: 'scan-2' });
  assert(visible(env, 'dashboard') && !visible(env, 'welcome'));
});

test('denied permission shows a partial-scan warning and the settings button', async () => {
  const { env, bridge } = await nativeEnv({ permissionStatus: () => ({ status: 'denied' }) });
  assert(visible(env, 'openSettingsBtn'));
  assert(env.get('permissionText').textContent.includes('kısmi'));
  await env.get('openSettingsBtn').click(); await settle();
  assert(bridge.calls.some(c => c.type === 'openFullDiskAccess'));
});

test('scan button sends startScan and progress events update the text', async () => {
  const { env, bridge } = await nativeEnv({ startScan: () => ({ started: true }) });
  await env.get('scanBtn').click(); await settle();
  assert.deepEqual(bridge.calls.find(c => c.type === 'startScan').payload, { scope: 'data' });
  assert(visible(env, 'scanning') && !visible(env, 'welcome'));
  assert(env.get('scanBtn').disabled);
  await env.run("window.diskAtlasEvent({event:'scanProgress',records:1234,errors:2,folder:'/Users/x',elapsed:3.2})"); await settle();
  const text = env.get('scanProgressText').textContent;
  assert(text.includes('1.234') && text.includes('/Users/x') && text.startsWith('00:03'), text);
});

test('scanDone loads the saved report and shows the dashboard', async () => {
  const { env, bridge } = await nativeEnv({ startScan: () => ({ started: true }), loadScan: () => makeReport() });
  await env.get('scanBtn').click(); await settle();
  await env.run("window.diskAtlasEvent({event:'scanDone',id:'scan-7'})"); await settle();
  assert.deepEqual(bridge.calls.find(c => c.type === 'loadScan').payload, { id: 'scan-7' });
  assert(visible(env, 'dashboard') && !visible(env, 'scanning') && !visible(env, 'welcome'));
  assert(!env.get('scanBtn').disabled);
});

test('cancel button sends cancelScan', async () => {
  const { env, bridge } = await nativeEnv({ startScan: () => ({ started: true }), cancelScan: () => ({}) });
  await env.get('scanBtn').click(); await settle();
  await env.get('cancelScanBtn').click(); await settle();
  assert(bridge.calls.some(c => c.type === 'cancelScan'));
});

test('scanFailed shows the message and returns to the welcome screen', async () => {
  const { env } = await nativeEnv({ startScan: () => ({ started: true }) });
  await env.get('scanBtn').click(); await settle();
  await env.run("window.diskAtlasEvent({event:'scanFailed',message:'Tarama kökü okunamadı: /x.'})"); await settle();
  assert(visible(env, 'message') && env.get('message').textContent.includes('/x'));
  assert(!visible(env, 'scanning') && visible(env, 'welcome'));
  assert(!env.get('scanBtn').disabled);
});

test('a bridge error is shown and the scan screen is closed', async () => {
  const { env } = await nativeEnv({ startScan: () => { throw new Error('Tarama zaten sürüyor.'); } });
  await env.get('scanBtn').click(); await settle();
  assert(visible(env, 'message') && env.get('message').textContent.includes('Tarama zaten sürüyor.'));
  assert(!visible(env, 'scanning'));
});

test('validate accepts schema 1 and 2 and rejects others', () => {
  const env = boot();
  assert.doesNotThrow(() => env.run(`validate(${JSON.stringify(makeReport())})`));
  assert.doesNotThrow(() => env.run(`validate(${JSON.stringify(makeReport({ schema: 1 }))})`));
  assert.throws(() => env.run(`validate(${JSON.stringify(makeReport({ schema: 3 }))})`));
});

test('file mode hides the scan button and keeps the import flow', async () => {
  const env = boot();
  await env.ready(); await settle();
  assert(!visible(env, 'scanBtn') && !visible(env, 'welcomeNative'));
  assert(visible(env, 'welcome') && visible(env, 'welcomeFile'));
});

test('a saved scan with denied permission keeps a persistent banner with the settings button', async () => {
  const { env, bridge } = await nativeEnv({ permissionStatus: () => ({ status: 'denied' }), listScans: () => [{ id: 'scan-1' }], loadScan: () => makeReport() });
  assert(visible(env, 'dashboard') && visible(env, 'permissionBanner'));
  await env.get('openSettingsBanner').click(); await settle();
  assert(bridge.calls.some(c => c.type === 'openFullDiskAccess'));
});

test('granted permission hides the banner and a new scan hides it while scanning', async () => {
  const granted = await nativeEnv({ listScans: () => [{ id: 'scan-1' }], loadScan: () => makeReport() });
  assert(visible(granted.env, 'dashboard') && !visible(granted.env, 'permissionBanner'));
  const denied = await nativeEnv({ permissionStatus: () => ({ status: 'denied' }), listScans: () => [{ id: 'scan-1' }], loadScan: () => makeReport(), startScan: () => ({ started: true }) });
  await denied.env.get('scanBtn').click(); await settle();
  assert(!visible(denied.env, 'permissionBanner'));
});

test('a scan made without Full Disk Access is marked partial', async () => {
  const { env } = await nativeEnv({ listScans: () => [{ id: 'scan-1' }], loadScan: () => makeReport({ fullDiskAccess: 'denied' }) });
  assert(visible(env, 'message'));
  assert(env.get('message').textContent.includes('Tam Disk Erişimi'), env.get('message').textContent);
});

test('a user-cancelled or limited scan is described as partial without blaming a limit', async () => {
  const { env } = await nativeEnv({ listScans: () => [{ id: 'scan-1' }], loadScan: () => makeReport({ incomplete: true }) });
  assert(env.get('message').textContent.includes('iptal'), env.get('message').textContent);
});

test('native help describes scanning instead of claiming the page never touches the disk', async () => {
  const { env } = await nativeEnv();
  await env.get('helpBtn').click();
  const text = env.get('dialogBody').textContent;
  assert(text.includes('yalnızca adını, yolunu ve boyutunu okur'), text);
  assert(!text.includes('diske kendiliğinden erişmez'), text);
  const fileEnv = boot();
  await fileEnv.get('helpBtn').click();
  assert(fileEnv.get('dialogBody').textContent.includes('diske kendiliğinden erişmez'));
});

// ---- Geçmiş ve karşılaştırma ----
const scans = [
  { id: 'scan-3', created: '2026-10-19T09:00:00.000000+00:00', scope: '/', incomplete: false, allocatedBytes: 10e9, schema: 2, fullDiskAccess: 'granted', comparable: true },
  { id: 'scan-2', created: '2026-10-18T09:00:00.000000+00:00', scope: '/', incomplete: true, allocatedBytes: 9e9, schema: 2, fullDiskAccess: 'denied', comparable: true },
  { id: 'scan-1', created: '2026-10-17T09:00:00.000000+00:00', scope: '/', incomplete: false, allocatedBytes: 8e9, schema: 1, comparable: false }
];
const compareData = (items, extra = {}) => ({
  olderId: 'scan-2', newerId: 'scan-3', olderCreated: scans[1].created, newerCreated: scans[0].created,
  diff: { measuredDelta: 3e9, diskUsedDelta: 10e9, unexplained: 7e9, warnings: [], items, totalItems: items.length, ...extra }
});
const sampleItems = [
  { path: '/Users/x/Library', before: 5e9, after: 9e9, delta: 4e9, status: 'grew' },
  { path: '/Users/x/Old', before: 3e9, after: null, delta: -3e9, status: 'gone' },
  { path: '/Users/x/Mail', before: 2e9, after: 4e9, delta: 2e9, status: 'uncertain', reason: 'Okunamayan klasör içeriyor' }
];
const historyEnv = async (handlers = {}) => {
  const result = await nativeEnv({ listScans: () => scans, loadScan: () => makeReport(), ...handlers });
  await result.env.get('historyNav').click(); await settle();
  return result;
};
const rows = env => env.get('historyList').children;
const buttonsOf = (node, text) => node.querySelectorAll('button').filter(b => b.textContent === text);
const check = (env, index, on = true) => { const box = env.get('historyList').querySelectorAll('input')[index]; box.checked = on; box.onchange(); };

test('history tab is visible only in native mode', async () => {
  const { env } = await nativeEnv();
  assert(visible(env, 'historyNav'));
  const fileEnv = boot(); await fileEnv.ready();
  assert(!visible(fileEnv, 'historyNav'));
});

test('history lists scans newest first with badges', async () => {
  const { env } = await historyEnv();
  assert(visible(env, 'view-history') && !visible(env, 'view-explorer'));
  assert.equal(rows(env).length, 3);
  const texts = rows(env).map(row => row.textContent);
  assert(texts[0].includes('GiB') && !texts[0].includes('Kısmi'), texts[0]);
  assert(texts[1].includes('Kısmi') && texts[1].includes('İzinsiz'), texts[1]);
  assert(texts[2].includes('Karşılaştırılamaz'), texts[2]);
});

test('compare needs exactly two selections and a non-comparable scan cannot be picked', async () => {
  const { env } = await historyEnv();
  const boxes = env.get('historyList').querySelectorAll('input');
  assert(boxes[2].disabled && !boxes[0].disabled);
  assert(env.get('compareBtn').disabled);
  check(env, 0); assert(env.get('compareBtn').disabled);
  check(env, 1); assert(!env.get('compareBtn').disabled);
  check(env, 1, false); assert(env.get('compareBtn').disabled);
});

test('compare sends both ids and renders a table sorted as delivered with signed deltas', async () => {
  const { env, bridge } = await historyEnv({ compare: () => compareData(sampleItems) });
  check(env, 0); check(env, 1);
  await env.get('compareBtn').click(); await settle();
  const call = bridge.calls.find(c => c.type === 'compare');
  assert.deepEqual([call.payload.older, call.payload.newer].sort(), ['scan-2', 'scan-3']);
  assert(visible(env, 'compareResult'));
  const body = env.get('compareBody').children;
  assert.equal(body.length, 3);
  assert(body[0].textContent.includes('/Users/x/Library') && body[0].textContent.includes('+') && body[0].textContent.includes('GiB'), body[0].textContent);
  assert(body[1].textContent.includes('−') && body[1].textContent.includes('Kalktı'), body[1].textContent);
  assert(body[1].textContent.includes('—'), 'after of a gone folder is a dash');
});

test('compare shows the unexplained card and warnings', async () => {
  const { env } = await historyEnv({ compare: () => compareData(sampleItems, { warnings: ['İki taramanın kapsamı farklı; yalnızca ortak klasörler karşılaştırılabilir.'] }) });
  check(env, 0); check(env, 1);
  await env.get('compareBtn').click(); await settle();
  const summary = env.get('compareSummary').textContent;
  assert(summary.includes('Açıklanamayan fark') && summary.includes('Disk doluluk') && summary.includes('Ölçülen'), summary);
  assert(env.get('compareWarnings').textContent.includes('kapsamı farklı'));
});

test('compare filter and search narrow the rows', async () => {
  const { env } = await historyEnv({ compare: () => compareData(sampleItems) });
  check(env, 0); check(env, 1);
  await env.get('compareBtn').click(); await settle();
  const filter = name => env.get('filter-' + name);
  filter('newgone').click();
  assert.equal(env.get('compareBody').children.length, 1);
  filter('uncertain').click();
  assert.equal(env.get('compareBody').children.length, 1);
  filter('all').click();
  env.get('compareSearch').value = 'library'; env.get('compareSearch').oninput();
  assert.equal(env.get('compareBody').children.length, 1);
});

test('uncertain rows show the reason', async () => {
  const { env } = await historyEnv({ compare: () => compareData(sampleItems) });
  check(env, 0); check(env, 1);
  await env.get('compareBtn').click(); await settle();
  const uncertain = env.get('compareBody').children.find(row => row.textContent.includes('Belirsiz'));
  assert(uncertain.textContent.includes('Okunamayan klasör içeriyor'), uncertain.textContent);
});

test('open loads the report and switches to the explorer', async () => {
  const { env, bridge } = await historyEnv();
  const before = bridge.calls.filter(c => c.type === 'loadScan').length;
  await buttonsOf(rows(env)[1], 'Aç')[0].click(); await settle();
  const loads = bridge.calls.filter(c => c.type === 'loadScan');
  assert.equal(loads.length, before + 1);
  assert.deepEqual(loads.at(-1).payload, { id: 'scan-2' });
  assert(visible(env, 'view-explorer') && !visible(env, 'view-history'));
});

test('delete asks for confirmation, then refreshes the list and keeps the open dashboard', async () => {
  let list = scans;
  const { env, bridge } = await historyEnv({ listScans: () => list, deleteScan: payload => { list = list.filter(s => s.id !== payload.id); return {}; } });
  await buttonsOf(rows(env)[2], 'Sil')[0].click(); await settle();
  assert(!env.get('dialogBackdrop').classList.contains('hidden'));
  assert(!bridge.calls.some(c => c.type === 'deleteScan'));
  assert(env.get('dialogBody').textContent.includes('dosyalarına dokunulmaz'));
  await buttonsOf(env.get('dialogBody'), 'Sil')[0].click(); await settle();
  assert.deepEqual(bridge.calls.find(c => c.type === 'deleteScan').payload, { id: 'scan-1' });
  assert.equal(rows(env).length, 2);
  assert(env.get('dialogBackdrop').classList.contains('hidden'));
  assert(visible(env, 'dashboard'));
});

test('cancelling the delete dialog deletes nothing', async () => {
  const { env, bridge } = await historyEnv();
  await buttonsOf(rows(env)[0], 'Sil')[0].click(); await settle();
  await buttonsOf(env.get('dialogBody'), 'Vazgeç')[0].click(); await settle();
  assert(!bridge.calls.some(c => c.type === 'deleteScan'));
  assert(env.get('dialogBackdrop').classList.contains('hidden'));
});

test('a compare error is shown', async () => {
  const { env } = await historyEnv({ compare: () => { throw new Error('Eski tarama karşılaştırma için gerekli ayrıntıyı içermiyor (eski sürümden).'); } });
  check(env, 0); check(env, 1);
  await env.get('compareBtn').click(); await settle();
  assert(visible(env, 'message') && env.get('message').textContent.includes('karşılaştırma için gerekli'));
  assert(!visible(env, 'compareResult'));
});
