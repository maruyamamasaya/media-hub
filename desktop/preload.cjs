const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('photoHub', {
  chooseDirectory: () => ipcRenderer.invoke('choose-storage-directory'),
  chooseVideo: () => ipcRenderer.invoke('choose-light-video'),
});
