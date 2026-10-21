/*
 * Purpose: Persist Chrome download-to-Lanvi transfer mapping and acknowledge completed downloads.
 * Integration: Manifest V3 service worker. The dashboard starts downloads; this worker watches their final state.
 * Project: Lanvi | Developer attribution: Mayank Chawdhari AKA BOSS294
 */
'use strict';
const CONTROL = 'http://127.0.0.1:8788';
async function post(path, body) {
  const response = await fetch(`${CONTROL}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), cache: 'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Bridge returned HTTP ${response.status}`);
  return data;
}
async function removeMapping(downloadId) {
  const result = await chrome.storage.local.get({ lanviDownloadMap: {} });
  const map = result.lanviDownloadMap;
  delete map[String(downloadId)];
  await chrome.storage.local.set({ lanviDownloadMap: map });
}
async function finishDownload(downloadId, status, error = '') {
  const result = await chrome.storage.local.get({ lanviDownloadMap: {} });
  const item = result.lanviDownloadMap[String(downloadId)];
  if (!item) return;
  try {
    if (status === 'complete') await post('/api/ack', { id: item.bridgeFileId, status: 'complete' });
    else await post('/api/download-result', { id: item.bridgeFileId, status: 'interrupted', downloadId, error: error || 'Chrome download was interrupted.' });
  } catch (failure) {
    console.warn('[Lanvi] Could not update bridge transfer status:', failure.message);
  }
  await removeMapping(downloadId);
  try { await chrome.runtime.sendMessage({ type: 'LANVI_DOWNLOAD_UPDATED', bridgeFileId: item.bridgeFileId, status }).catch(() => {}); } catch { /* Dashboard may be closed. */ }
}
chrome.downloads.onChanged.addListener((delta) => {
  if (delta.state?.current === 'complete') void finishDownload(delta.id, 'complete');
  else if (delta.state?.current === 'interrupted') void finishDownload(delta.id, 'interrupted', delta.error?.current || 'Chrome download was interrupted.');
});
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === 'LANVI_DOWNLOAD_COMPLETE') void finishDownload(message.downloadId, 'complete');
  if (message?.type === 'LANVI_DOWNLOAD_INTERRUPTED') void finishDownload(message.downloadId, 'interrupted', message.error || 'Chrome download was interrupted.');
});
