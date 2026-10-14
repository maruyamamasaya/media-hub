const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { startApi } = require('./api-process.cjs');
const { pythonExecutable } = require('./platform.cjs');
const root = path.resolve(__dirname, '..');
const python = pythonExecutable(root);

test('managed API preserves originals across restart and reports crashes', { timeout: 30000 }, async () => {
  const folder = path.join(root, '.local/test-runs');
  fs.mkdirSync(folder, { recursive: true });
  const dataRoot = fs.mkdtempSync(path.join(folder, 'desktop-node-'));
  let running;
  try {
    running = startApi({ root, dataRoot, python });
    const { origin, token } = await running.ready;
    const headers = { 'X-Photo-Hub-Token': token };
    const source = path.join(dataRoot, 'source');
    fs.mkdirSync(source);
    const raw = fs.readFileSync(path.join(root, '.local/fixtures/sample-0001.png'));
    fs.writeFileSync(path.join(source, 'sample.png'), raw);
    assert.equal((await fetch(`${origin}/api/v1/imports`, {method: 'POST', headers, body: new FormData()})).status, 410);
    assert.deepEqual(await (await fetch(`${origin}/api/v1/folder-library`, {headers})).json(), []);
    assert.deepEqual(fs.readFileSync(path.join(source, 'sample.png')), raw);
    const duplicate = startApi({ root, dataRoot, python });
    try { await assert.rejects(duplicate.ready); } finally { await duplicate.stop(); }
    await running.stop();
    await assert.rejects(fetch(`${origin}/api/v1/status`, { headers, signal: AbortSignal.timeout(2000) }));
    let notify;
    const crashed = new Promise(resolve => { notify = resolve; });
    running = startApi({ root, dataRoot, python, onExit: notify });
    const next = await running.ready;
    const nextHeaders = { 'X-Photo-Hub-Token': next.token };
    assert.deepEqual(fs.readFileSync(path.join(source, 'sample.png')), raw);
    assert.deepEqual(await (await fetch(`${next.origin}/api/v1/folder-library`, {headers: nextHeaders})).json(), []);
    assert.equal((await fetch(`${next.origin}/api/v1/status`, { headers })).status, 401);
    // Kill the actual API, not Windows' venv launcher; notification must reach main.
    process.kill(running.serverPid);
    await crashed;
    await running.stop();
  } finally {
    if (running) await running.stop();
    fs.rmSync(dataRoot, { recursive: true, force: true });
  }
});
