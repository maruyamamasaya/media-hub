// Real Chromium/UI/API checks in an isolated library. No personal files are used.
const { app, BrowserWindow, session } = require('electron');
const { startApi } = require('./api-process.cjs');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(root, '.local/test-runs'), { recursive: true });
const testRoot = fs.mkdtempSync(path.join(root, '.local/test-runs/short-ui-'));
const python = path.join(root, '.venv/Scripts/python.exe');
app.setPath('userData', path.join(testRoot, 'profile'));
let server;
let window;
async function js(code) { return window.webContents.executeJavaScript(code, true); }
async function wait(expression) {
  await js(`new Promise((resolve, reject) => { let n = 0; const timer = setInterval(() => { if (${expression}) { clearInterval(timer); resolve(true); } else if (++n > 150) { clearInterval(timer); reject(new Error('UI timeout: ' + ${JSON.stringify(expression)})); } }, 50); })`);
}
async function click(text) { await js(`Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === ${JSON.stringify(text)}).click()`); }
function assert(value, message) { if (!value) throw new Error(message); }
app.whenReady().then(async () => {
  try {
    server = startApi({ root, dataRoot: path.join(testRoot, 'library'), python });
    const { origin, token } = await server.ready;
    const isolated = session.fromPartition('short-ui-' + Date.now());
    const requests = [];
    isolated.webRequest.onBeforeSendHeaders((details, done) => {
      requests.push(details.url);
      details.requestHeaders['X-Photo-Hub-Token'] = token;
      done({ requestHeaders: details.requestHeaders });
    });
    window = new BrowserWindow({ show: false, width: 1200, height: 900, webPreferences: { session: isolated, contextIsolation: true, nodeIntegration: false, sandbox: true } });
    await window.loadURL(origin);
    await wait("document.querySelector('[aria-label=ライブラリ]')");
    await click('マイショート');
    await wait("document.querySelector('.short-stage').textContent.includes('対象の素材がありません')");
    const recording = await js(`new Promise(resolve => {
      const canvas = document.createElement('canvas'); canvas.width = 160; canvas.height = 100;
      const context = canvas.getContext('2d'); const stream = canvas.captureStream(10);
      const recorder = new MediaRecorder(stream, {mimeType: 'video/webm;codecs=vp8'}); const chunks = [];
      recorder.ondataavailable = e => chunks.push(e.data);
      recorder.onstop = async () => { const reader = new FileReader(); reader.onload = () => resolve(reader.result.split(',')[1]); reader.readAsDataURL(new Blob(chunks, {type: 'video/webm'})); stream.getTracks().forEach(t => t.stop()); };
      recorder.start(); let frame = 0; const timer = setInterval(() => { context.fillStyle = frame++ % 2 ? 'orange' : 'green'; context.fillRect(0, 0, 160, 100); }, 100);
      setTimeout(() => { clearInterval(timer); recorder.stop(); }, 1200);
    })`);
    fs.writeFileSync(path.join(testRoot, 'clip.webm'), Buffer.from(recording, 'base64'));
    execFileSync(python, [path.join(root, 'scripts/create-short-test-fixture.py'), testRoot], { windowsHide: true });
    await window.reload();
    await wait("document.querySelector('.asset-grid img')?.naturalWidth > 0");
    await click('マイショート');
    await wait("document.querySelector('.my-short footer strong')");
    const names = [];
    for (let n = 0; n < 4; n++) {
      const name = await js("document.querySelector('.my-short footer strong').textContent");
      assert(!names.includes(name), 'Session repeated a material'); names.push(name);
      if (n < 3) { await click('次へ'); await wait(`document.querySelector('.my-short footer strong').textContent !== ${JSON.stringify(name)}`); }
    }
    await click('前へ');
    assert(await js("document.querySelector('.my-short footer strong').textContent") === names[2], 'Back history mismatch');
    await js("for (let i=0;i<12;i++) document.querySelector('.short-stage').dispatchEvent(new WheelEvent('wheel', {deltaY:100,bubbles:true}));");
    await wait(`document.querySelector('.my-short footer strong').textContent === ${JSON.stringify(names[3])}`);
    await js("document.querySelector('.short-stage').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowUp',bubbles:true}));");
    await wait(`document.querySelector('.my-short footer strong').textContent === ${JSON.stringify(names[2])}`);
    await js("document.querySelector('.short-stage').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowUp',repeat:true,bubbles:true}));");
    assert(await js("document.querySelector('.my-short footer strong').textContent") === names[2], 'Held key repeated navigation');
    await js(`const stage = document.querySelector('.short-stage');
      const start = new Event('touchstart', {bubbles:true}); Object.defineProperty(start,'touches',{value:[{clientX:200,clientY:200}]}); stage.dispatchEvent(start);
      const end = new Event('touchend', {bubbles:true}); Object.defineProperty(end,'changedTouches',{value:[{clientX:200,clientY:100}]}); stage.dispatchEvent(end);`);
    await wait(`document.querySelector('.my-short footer strong').textContent === ${JSON.stringify(names[3])}`);
    await click('前へ');
    await click('♡ お気に入り'); await wait("document.querySelector('.short-actions [aria-pressed=true]')");
    await js("const select = document.querySelector('.short-actions select'); select.value = select.options[1].value; select.dispatchEvent(new Event('change', {bubbles:true}));");
    await wait("!document.querySelector('.short-actions select').disabled");
    await click('素材の詳細'); await wait("document.querySelector('.detail-layout')");
    assert(await js("document.querySelector('.collection-check input').checked"), 'Collection did not persist');
    assert(await js("!!document.querySelector('a[download]')"), 'Original download missing');
    await js("document.querySelector('[aria-label=閉じる]').click()");
    while (await js("document.querySelector('.my-short footer strong').textContent") !== 'clip') {
      const previous = await js("document.querySelector('.my-short footer strong').textContent");
      await click(names.indexOf('clip') > names.indexOf(previous) ? '次へ' : '前へ');
      await wait(`document.querySelector('.my-short footer strong').textContent !== ${JSON.stringify(previous)}`);
    }
    await wait("document.querySelector('.short-stage video')?.readyState >= 2");
    assert(await js("document.querySelector('.short-stage video').muted"), 'Video must start muted');
    await js("window.oldVideo = document.querySelector('.short-stage video'); oldVideo.play()");
    await click('素材の詳細'); await wait("document.querySelector('.detail-layout')");
    assert(await js('oldVideo.paused'), 'Video did not pause for detail');
    await js("document.querySelector('[aria-label=閉じる]').click()");
    await wait("!document.querySelector('.detail-layout')");
    await js("oldVideo.play(); oldVideo.muted = false; oldVideo.pause()");
    assert(await js('oldVideo.paused && !oldVideo.muted'), 'Video controls failed');
    await js("oldVideo.play()");
    fs.writeFileSync(path.join(testRoot, 'my-short.png'), (await window.webContents.capturePage()).toPNG());
    await js("Array.from(document.querySelectorAll('[aria-label=ライブラリ] button')).find(b => b.textContent.includes('通常の素材')).click()");
    await wait("!document.querySelector('.my-short')");
    assert(await js('oldVideo.paused'), 'Video did not stop on leaving screen');
    const response = await fetch(origin + '/api/v1/assets', { headers: {'X-Photo-Hub-Token': token} });
    const assets = (await response.json()).items;
    const originals = assets.flatMap(a => a.files.filter(f => f.role === 'original').map(f => `/files/${f.id}/content`));
    assert(!requests.some(url => originals.some(fragment => url.includes(fragment))), 'UI fetched an original');
    console.log('PASS: MyShort empty, unique/back, wheel burst, keyboard, touch, favorite, collection, detail, muted playback, stop, derived-only requests');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
  finally { window?.destroy(); await server?.stop(); app.exit(process.exitCode || 0); }
});
