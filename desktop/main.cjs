const { app, BrowserWindow, session, dialog, Menu, ipcMain } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { startApi } = require('./api-process.cjs');
const { execFile } = require('node:child_process');
const { pythonExecutable, menuTemplate } = require('./platform.cjs');
const launchedAt = Date.now();

const root = path.resolve(__dirname, '..');
// Independent library by default; explicit handoff can open the stopped Web library.
const smoke = process.argv.includes('--smoke-test');
const useWebLibrary = process.argv.includes('--web-library');
const dataRoot = path.join(root, smoke ? '.local/desktop-smoke-library' : useWebLibrary ? '.local/asset-library' : '.local/desktop-library');
app.setPath('userData', path.join(root, smoke ? '.local/desktop-smoke-profile' : '.local/desktop-profile'));
let apiProcess;
let window;
let quitting = false;
let canQuit = false;
let secondarySeen = false;
let reopenWindow;
let apiReady = false;
if (!app.requestSingleInstanceLock()) app.exit(0);
else {
  app.on('second-instance', () => {
    secondarySeen = true;
    if (smoke || quitting) return;
    if (window && !window.isDestroyed()) { if (window.isMinimized()) window.restore(); window.focus(); }
    else reopenWindow?.();
  });
  app.on('activate', () => { if (!quitting && (!window || window.isDestroyed())) reopenWindow?.(); });
  app.on('before-quit', event => {
    if (canQuit || !apiProcess) return;
    event.preventDefault();
    if (quitting) return;
    quitting = true;
    if (window && !window.isDestroyed()) window.destroy();
    apiProcess.stop().finally(() => { canQuit = true; if (process.exitCode) app.exit(process.exitCode); else app.quit(); });
  });
  app.on('window-all-closed', () => { if (!quitting && process.platform !== 'darwin') app.quit(); });
  app.whenReady().then(async () => {
    try {
      if (!fs.existsSync(path.join(root, 'web/dist/index.html'))) throw new Error('先にWebをビルドしてください。');
      apiProcess = startApi({ root, dataRoot,
        python: pythonExecutable(root, process.platform),
        onExit: () => {
          if (quitting || !apiReady) return;
          if (smoke) { console.error('API stopped unexpectedly'); process.exitCode = 1; app.quit(); return; }
          dialog.showErrorBox('Photo Hub', 'ローカルAPIが停止しました。アプリを起動し直してください。保存済みの素材は保持されています。');
          app.quit();
        },
      });
      const { origin, token } = await apiProcess.ready;
      apiReady = true;
      const startedAt = Date.now();
      ipcMain.handle('choose-storage-directory', async event => {
        if (!window || event.sender !== window.webContents || new URL(event.sender.getURL()).origin !== origin) throw new Error('Invalid sender');
        const result = await dialog.showOpenDialog(window, { title: 'メディアフォルダを選択', properties: ['openDirectory'] });
        return result.canceled ? null : result.filePaths[0];
      });
      ipcMain.handle('choose-light-video', async event => {
        if (!window || event.sender !== window.webContents || new URL(event.sender.getURL()).origin !== origin) throw new Error('Invalid sender');
        const result = await dialog.showOpenDialog(window, { title: '軽量版を作る動画を選択', properties: ['openFile'], filters: [{ name: '動画', extensions: ['mov', 'mp4', 'm4v', 'mkv', 'webm'] }] });
        return result.canceled ? null : result.filePaths[0];
      });
      const isolated = session.fromPartition('photo-hub-desktop');
      isolated.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
      isolated.setPermissionCheckHandler(() => false);
      isolated.webRequest.onBeforeRequest((details, callback) => {
        const local = new URL(details.url).origin === origin;
        callback({ cancel: !local && !details.url.startsWith('blob:') && !details.url.startsWith('data:') });
      });
      isolated.webRequest.onBeforeSendHeaders((details, callback) => {
        if (new URL(details.url).origin === origin) details.requestHeaders['X-Photo-Hub-Token'] = token;
        callback({ requestHeaders: details.requestHeaders });
      });
      const openWindow = async () => {
        if (quitting || (window && !window.isDestroyed())) return;
        const created = new BrowserWindow({ width: 1280, height: 900, minWidth: 900, minHeight: 600,
          show: false, title: 'Photo Hub', backgroundColor: '#faf9f6',
          webPreferences: { session: isolated, preload: path.join(__dirname, 'preload.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true },
        });
        window = created;
        created.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
        created.webContents.on('will-navigate', (event, url) => { if (new URL(url).origin !== origin) event.preventDefault(); });
        created.on('closed', () => { if (window === created) window = null; });
        await created.loadURL(origin);
        if (!smoke && !quitting && !created.isDestroyed()) created.show();
      };
      reopenWindow = () => openWindow().catch(error => { dialog.showErrorBox('Photo Hub', error.message); app.quit(); });
      Menu.setApplicationMenu(Menu.buildFromTemplate(menuTemplate(process.platform, () => {
        const options = { message: '試作用ライブラリ', detail: dataRoot };
        return window && !window.isDestroyed() ? dialog.showMessageBox(window, options) : dialog.showMessageBox(options);
      })));
      await openWindow();
      if (smoke) {
        await new Promise((resolve, reject) => execFile(process.execPath, [__dirname, '--smoke-test'], { windowsHide: true, timeout: 10000 }, error => error ? reject(error) : resolve()));
        if (!secondarySeen) throw new Error('二重起動の抑止を確認できませんでした。');
        const ready = await window.webContents.executeJavaScript(`new Promise((resolve, reject) => {
          let attempts = 0;
          const timer = setInterval(() => {
            const shell = document.querySelector('.cloud-app');
            if (shell && document.body.innerText.includes('保存済みフォルダ')) { clearInterval(timer); resolve(document.body.innerText); }
            else if (document.querySelector('.error-box')) { clearInterval(timer); reject(new Error('UI API request failed')); }
            else if (++attempts > 100) { clearInterval(timer); reject(new Error('UI readiness timeout')); }
          }, 100);
        })`);
        if (!ready.includes('S3フォルダ') || !ready.includes('アップロード')) throw new Error('S3専用UIを確認できませんでした。');
        const output = path.join(root, '.local/desktop-smoke.png');
        fs.writeFileSync(output, (await window.webContents.capturePage()).toPNG());
        fs.writeFileSync(path.join(root, '.local/desktop-smoke-metrics.json'), JSON.stringify({ totalSmokeMs: Date.now() - launchedAt, uiReadyMsAfterApi: Date.now() - startedAt, secondarySeen, processes: app.getAppMetrics().map(({ type, memory }) => ({ type, memory })) }, null, 2));
        console.log('PASS: desktop UI loaded; screenshot .local/desktop-smoke.png');
        app.quit();
      }
    } catch (error) {
      if (smoke) { console.error(error.message); process.exitCode = 1; }
      else dialog.showErrorBox('Photo Hubを起動できません', error.message);
      app.quit();
    }
  });
}
