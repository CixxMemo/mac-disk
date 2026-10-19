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
