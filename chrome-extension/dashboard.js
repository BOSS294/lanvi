/*
 * Purpose: Pairing, receiver status, Chrome Downloads handoff, and local activity history.
 * Integration: dashboard.html; uses only the loopback-only PC control API.
 * Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
 * Changelog: encrypted-payload status and verified local transfer lifecycle; API contract remains loopback-only.
 */
'use strict';

const CONTROL = 'http://127.0.0.1:8788';
const $ = (id) => document.getElementById(id);
let bridgeOnline = false;
let currentPairingUrl = '';
let currentPairingExpiresAt = 0;
let latestStatus = null;
let polling = false;
let processLocked = false;
let toastTimer = null;
let qrObjectUrl = null;
let renderedActivityKey = '';
let renderedDevicesKey = '';
let lastDevicesPollAt = 0;

function icon(name, className = 'ph-icon') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', className);
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', `#ph-${name}`);
  svg.append(use);
  return svg;
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let amount = bytes / 1024;
  let index = 0;
  while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index += 1; }
  return `${amount.toFixed(amount >= 100 ? 0 : 1)} ${units[index]}`;
}

function timeLabel(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function showToast(message, type = 'success') {
  const toast = $('toast');
  $('toastMessage').textContent = message;
  toast.classList.toggle('error', type === 'error');
  const use = toast.querySelector('.toast-icon use');
  if (use) use.setAttribute('href', type === 'error' ? '#ph-x-circle' : '#ph-check-circle');
  toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('visible'), 3200);
}

async function api(path, options = {}) {
  const response = await fetch(`${CONTROL}${path}`, { cache: 'no-store', ...options });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `Local bridge returned HTTP ${response.status}`);
  return body;
}

async function post(path, body = {}) {
  return api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
}

function setBridgeState(online, label) {
  bridgeOnline = online;
  const badge = $('bridgeBadge');
  badge.classList.toggle('online', online);
  badge.classList.toggle('offline', !online);
  badge.classList.remove('checking');
  $('bridgeLabel').textContent = label;
  $('connectionMetric').textContent = online ? 'Online' : 'Offline';
  $('connectionFootnote').textContent = online ? 'PC is reachable on your local network' : 'Start the PC bridge to reconnect';
  $('receiverLiveIndicator').classList.toggle('online', online);
  $('computer-state-dot').classList?.toggle?.('online', online);
}

function setSelectAddresses(addresses, preferred) {
  const select = $('lanAddress');
  const old = select.value;
  const nextSignature = addresses.map((item) => `${item.address}|${item.name}`).join(';');
  if (select.dataset.signature === nextSignature) return;
  select.dataset.signature = nextSignature;
  select.replaceChildren();
  if (!addresses.length) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'No LAN address found';
    select.append(option);
    return;
  }
  for (const item of addresses) {
    const option = document.createElement('option');
    option.value = item.address;
    option.textContent = `${item.address} · ${item.name}`;
    select.append(option);
  }
  const valid = addresses.some((item) => item.address === old);
  select.value = valid ? old : (addresses.some((item) => item.address === preferred) ? preferred : addresses[0].address);
}

function setPairingState(label, type = 'waiting') {
  const pill = $('pairingState');
  pill.classList.remove('waiting', 'error', 'ready');
  pill.classList.add(type);
  pill.replaceChildren();
  const dot = document.createElement('span');
  dot.className = 'pill-dot';
  pill.append(dot, document.createTextNode(label));
}

function setQrPlaceholder(label) {
  const placeholder = document.createElement('div');
  placeholder.className = 'qr-placeholder';
  const logo = document.createElement('span');
  logo.className = 'qr-logo';
  logo.textContent = 'L';
  const text = document.createElement('small');
  text.textContent = label;
  placeholder.append(logo, text);
  $('qrHolder').replaceChildren(placeholder);
}

async function loadPairing() {
  const host = $('lanAddress').value;
  if (!host) return;
  try {
    const data = await api(`/api/pairing?host=${encodeURIComponent(host)}`);
    currentPairingUrl = data.pairingUrl;
    currentPairingExpiresAt = Date.parse(data.expiresAt) || 0;
    $('pairingUrl').textContent = data.pairingUrl;
    setPairingState('QR ready', 'ready');
    $('expiryLabel').textContent = new Date(data.expiresAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (qrObjectUrl) URL.revokeObjectURL(qrObjectUrl);
    qrObjectUrl = URL.createObjectURL(new Blob([data.qrSvg], { type: 'image/svg+xml' }));
    const image = document.createElement('img');
    image.alt = 'Lanvi local pairing QR code';
    image.src = qrObjectUrl;
    image.addEventListener('error', () => setQrPlaceholder('QR unavailable'));
    $('qrHolder').replaceChildren(image);
    $('copyLinkBtn').disabled = false;
  } catch (error) {
    $('pairingUrl').textContent = error.message;
    setPairingState('Pairing unavailable', 'error');
    showToast(error.message, 'error');
  }
}

function setDiscoveryState(label, state = 'waiting') {
  const pill = $('devicesScanStatus');
  if (!pill) return;
  pill.className = `state-pill ${state}`;
  pill.replaceChildren();
  const dot = document.createElement('span');
  dot.className = 'pill-dot';
  pill.append(dot, document.createTextNode(label));
}

function deviceTypeLabel(type) {
  const value = String(type || 'unknown').toLowerCase();
  if (value === 'mobile') return 'Android phone';
  if (value === 'tablet') return 'Tablet';
  if (value === 'desktop') return 'Computer';
  return 'Lanvi device';
}

function capabilityLabel(value) {
  return String(value || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => ({
      'phone-to-pc': 'Send to PC',
      'chrome-downloads': 'Chrome Downloads',
      'send-to-pc': 'Can send to PC',
      'device-management': 'Device discovery',
      'lanvi-discovery': 'Local discovery',
      'media-library': 'Phone media library',
      'media-streaming': 'Encrypted media streaming',
      'media-player': 'Media player',
    })[part] || part)
    .join(' · ');
}

async function getDevicePreferences() {
  try {
    return await chrome.storage.local.get({ lanviDeviceAliases: {} });
  } catch {
    return { lanviDeviceAliases: {} };
  }
}

async function renameDiscoveredDevice(device) {
  const current = String(device.alias || device.name || 'Lanvi device');
  const value = window.prompt('Choose a local display name. This changes only this PC’s label for the device.', current);
  if (value === null) return;
  const alias = value.trim();
  if (!alias || alias.length > 64) {
    showToast('Use a display name containing 1–64 characters.', 'error');
    return;
  }
  const prefs = await getDevicePreferences();
  const aliases = { ...(prefs.lanviDeviceAliases || {}), [device.deviceId]: alias };
  await chrome.storage.local.set({ lanviDeviceAliases: aliases });
  renderedDevicesKey = '';
  await refreshDiscoveredDevices(true);
  showToast('Device label saved on this PC.');
}

function makeDiscoveredDeviceCard(device, alias) {
  const card = document.createElement('article');
  card.className = 'discovered-device-card';

  const top = document.createElement('div');
  top.className = 'discovered-device-top';
  const glyph = document.createElement('span');
  glyph.className = 'discovered-device-icon';
  glyph.append(icon(device.deviceType === 'desktop' ? 'monitor' : 'device-mobile'));

  const copy = document.createElement('div');
  copy.className = 'discovered-device-copy';
  const title = document.createElement('strong');
  title.textContent = alias || device.name || 'Lanvi device';
  title.title = title.textContent;
  const type = document.createElement('small');
  type.textContent = `${deviceTypeLabel(device.deviceType)} · Lanvi ${device.appVersion || 'client'}`;
  copy.append(title, type);
  top.append(glyph, copy);

  const status = document.createElement('span');
  status.className = `discovered-device-status${device.online ? ' online' : ''}`;
  status.textContent = device.online ? 'Discovered · not trusted' : `Offline · last seen ${timeLabel(device.lastSeenAt)}`;

  const address = document.createElement('div');
  address.className = 'discovered-device-addresses';
  const addresses = Array.isArray(device.addresses) ? device.addresses.filter(Boolean) : [];
  address.textContent = addresses.length ? `${addresses.join(' · ')}${device.port ? `:${device.port}` : ''}` : 'Address not resolved yet';

  const capabilities = document.createElement('div');
  capabilities.className = 'discovered-device-capabilities';
  capabilities.textContent = capabilityLabel(device.capabilities) || 'Lanvi discovery only';

  const actions = document.createElement('div');
  actions.className = 'discovered-device-actions';
  const rename = document.createElement('button');
  rename.type = 'button';
  rename.className = 'small-button';
  rename.append(icon('pencil-simple'), document.createTextNode('Rename locally'));
  rename.addEventListener('click', () => void renameDiscoveredDevice({ ...device, alias }));
  actions.append(rename);

  if (device.deviceType === 'mobile') {
    const pair = document.createElement('button');
    pair.type = 'button';
    pair.className = 'small-button';
    pair.append(icon('link'), document.createTextNode('Pair using this PC QR'));
    pair.addEventListener('click', async () => {
      document.querySelector('#connection')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      await loadPairing();
      showToast('Scan this PC’s QR code from Lanvi on the phone. Discovery alone does not authorize transfer.');
    });
    actions.append(pair);
  } else {
    const note = document.createElement('span');
    note.className = 'no-action';
    note.textContent = 'Discovery only';
    actions.append(note);
  }

  card.append(top, status, address, capabilities, actions);
  return card;
}

function renderDiscoveredDevices(data, aliases = {}) {
  const list = $('discoveredDevicesList');
  if (!list) return;
  const devices = Array.isArray(data?.devices) ? data.devices : [];
  const rendered = devices.map((device) => ({ ...device, alias: aliases[device.deviceId] || '' }));
  const key = JSON.stringify({ scanning: Boolean(data?.scanning), devices: rendered.map((device) => [device.deviceId, device.name, device.alias, device.deviceType, device.addresses, device.port, device.online, device.lastSeenAt, device.capabilities, device.appVersion]) });
  $('devicesCount').textContent = `${devices.length} ${devices.length === 1 ? 'device' : 'devices'} found`;
  setDiscoveryState(data?.scanning ? 'Discovering on local network' : 'Discovery unavailable', data?.scanning ? 'ready' : 'error');
  if (key === renderedDevicesKey) return;
  renderedDevicesKey = key;
  if (rendered.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'devices-empty';
    const glyph = document.createElement('span');
    glyph.className = 'empty-state-icon';
    glyph.append(icon('radar'));
    const title = document.createElement('strong');
    title.textContent = data?.scanning ? 'Searching for Lanvi devices' : 'Discovery is not running';
    const description = document.createElement('p');
    description.textContent = 'Keep Lanvi open on another device and make sure local multicast is allowed. Discovery does not use the cloud and never grants transfer access.';
    empty.append(glyph, title, description);
    list.replaceChildren(empty);
    return;
  }
  list.replaceChildren(...rendered.map((device) => makeDiscoveredDeviceCard(device, device.alias)));
}

async function refreshDiscoveredDevices(force = false) {
  if (!bridgeOnline) {
    setDiscoveryState('Bridge offline', 'error');
    $('devicesCount').textContent = 'Discovery unavailable';
    return;
  }
  if (!force && Date.now() - lastDevicesPollAt < 4000) return;
  lastDevicesPollAt = Date.now();
  try {
    const [data, prefs] = await Promise.all([api('/api/devices'), getDevicePreferences()]);
    renderDiscoveredDevices(data, prefs.lanviDeviceAliases || {});
  } catch (error) {
    setDiscoveryState('Discovery unavailable', 'error');
    $('devicesCount').textContent = 'Could not load devices';
    const list = $('discoveredDevicesList');
    if (list && !list.querySelector('.discovery-error')) {
      const note = document.createElement('div');
      note.className = 'devices-empty discovery-error';
      const title = document.createElement('strong');
      title.textContent = 'Could not read local discovery';
      const text = document.createElement('p');
      text.textContent = error.message || 'The local bridge did not return discovery state.';
      note.append(title, text);
      list.replaceChildren(note);
    }
  }
}

async function rescanDiscoveredDevices() {
  const button = $('refreshDevicesBtn');
  if (!button) return;
  button.disabled = true;
  button.classList.add('is-spinning');
  try {
    await post('/api/discovery/refresh', {});
    lastDevicesPollAt = 0;
    await refreshDiscoveredDevices(true);
    showToast('Local network discovery refreshed.');
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    button.disabled = false;
    button.classList.remove('is-spinning');
  }
}

function statusPresentation(status) {
  const map = {
    staged: ['Queued', 'Waiting for Chrome to start the download.'],
    claimed: ['Starting', 'Chrome is preparing the download.'],
    downloading: ['Downloading', 'Chrome is receiving the file.'],
    completed: ['Completed', 'Chrome reported the download as complete.'],
    interrupted: ['Interrupted', 'The download was interrupted; retry is available.'],
    failed: ['Failed', 'The transfer needs attention before retrying.'],
  };
  return map[status] || [status || 'Unknown', ''];
}

function fileIconName(filename) {
  const name = String(filename || '').toLowerCase();
  if (/\.(png|jpe?g|gif|webp|bmp|heic|heif|avif|svg)$/.test(name)) return 'file-image';
  if (/\.(mp4|mov|m4v|avi|mkv|webm|wmv|3gp|mpeg|mpg)$/.test(name)) return 'film-strip';
  if (/\.pdf$/.test(name)) return 'file-pdf';
  return 'file';
}

function makeHistoryRow(item) {
  const row = document.createElement('article');
  row.className = 'transfer-item';
  row.dataset.status = item.status || 'unknown';

  const main = document.createElement('div');
  main.className = 'transfer-main';
  const fileIcon = document.createElement('span');
  fileIcon.className = 'file-icon';
  fileIcon.append(icon(fileIconName(item.filename)));
  const info = document.createElement('div');
  info.className = 'file-info';
  const filename = document.createElement('strong');
  filename.textContent = item.filename || 'Unnamed file';
  filename.title = item.filename || 'Unnamed file';
  const meta = document.createElement('div');
  meta.className = 'file-meta';
  meta.textContent = item.sha256 ? `SHA-256 · ${item.sha256.slice(0, 12)}…` : 'Local transfer';
  info.append(filename, meta);
  main.append(fileIcon, info);

  const statusCell = document.createElement('div');
  statusCell.className = 'file-status-cell';
  const presentation = statusPresentation(item.status);
  const badge = document.createElement('span');
  badge.className = `status-pill ${String(item.status || 'unknown').replace(/[^a-z-]/g, '')}`;
  badge.textContent = presentation[0];
  badge.title = item.error || presentation[1];
  statusCell.append(badge);

  const dateCell = document.createElement('div');
  dateCell.className = 'file-date-cell';
  dateCell.textContent = timeLabel(item.receivedAt);
  dateCell.title = item.receivedAt ? new Date(item.receivedAt).toLocaleString() : '';

  const sizeCell = document.createElement('div');
  sizeCell.className = 'file-size-cell';
  sizeCell.textContent = formatBytes(item.size);

  const actions = document.createElement('div');
  actions.className = 'transfer-actions';
  if (['failed', 'interrupted'].includes(item.status)) {
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.className = 'small-button';
    retry.append(icon('arrow-counter-clockwise'), document.createTextNode('Retry'));
    retry.addEventListener('click', async () => {
      retry.disabled = true;
      try {
        await post('/api/retry', { id: item.id });
        showToast('Transfer queued for retry.');
        await refreshDashboard();
      } catch (error) {
        showToast(error.message, 'error');
      } finally {
        retry.disabled = false;
      }
    });
    actions.append(retry);
  } else if (item.sha256) {
    const copyHash = document.createElement('button');
    copyHash.type = 'button';
    copyHash.className = 'small-button hash-button';
    copyHash.title = 'Copy SHA-256 checksum';
    copyHash.setAttribute('aria-label', `Copy checksum for ${item.filename || 'file'}`);
    copyHash.append(icon('copy'), document.createTextNode('Hash'));
    copyHash.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(item.sha256);
        showToast('SHA-256 checksum copied.');
      } catch {
        showToast(`SHA-256: ${item.sha256}`, 'error');
      }
    });
    actions.append(copyHash);
  } else {
    actions.textContent = '—';
    actions.classList.add('no-action');
  }

  row.append(main, statusCell, dateCell, sizeCell, actions);
  if (item.error) {
    row.title = item.error;
    badge.title = `${presentation[1]} ${item.error}`;
  }
  return row;
}

function renderActivities(files) {
  const query = $('activitySearch').value.trim().toLocaleLowerCase();
  const statusFilter = $('activityFilter').value;
  const filtered = files.filter((item) => {
    const matchesQuery = !query || String(item.filename || '').toLocaleLowerCase().includes(query);
    const matchesStatus = statusFilter === 'all' || item.status === statusFilter;
    return matchesQuery && matchesStatus;
  });
  $('emptyState').hidden = files.length > 0;
  $('noSearchResults').hidden = files.length === 0 || filtered.length > 0;
  $('transferList').hidden = filtered.length === 0;
  $('activityShowing').textContent = files.length === 0 ? 'No activity to display' : (filtered.length === files.length ? `Showing ${filtered.length} ${filtered.length === 1 ? 'transfer' : 'transfers'}` : `Showing ${filtered.length} of ${files.length} transfers`);
  const key = JSON.stringify({ query, statusFilter, items: filtered.map((item) => [item.id, item.filename, item.size, item.status, item.receivedAt, item.sha256, item.error]) });
  if (key !== renderedActivityKey) {
    renderedActivityKey = key;
    $('transferList').replaceChildren(...filtered.map(makeHistoryRow));
  }
  const hasHistory = files.some((item) => !['staged', 'claimed', 'downloading'].includes(item.status));
  $('clearHistoryBtn').disabled = !hasHistory;
}

function renderStatus(status) {
  latestStatus = status;
  setBridgeState(true, 'PC bridge online');
  $('pcName').textContent = status.pcName || 'This PC';
  $('lanEndpoint').textContent = `Local receiver · port ${status.lanPort}`;
  $('rotateBtn').disabled = false;
  setSelectAddresses(status.addresses || [], status.addresses?.[0]?.address);
  const security = status.transportSecurity || {};
  const payloadEncrypted = security.payloadEncryption === 'aes-256-gcm-chunked-v1';
  $('securityTitle').textContent = payloadEncrypted ? 'Encrypted local transfer' : 'Transport security unavailable';
  $('securityText').textContent = payloadEncrypted
    ? 'File contents use chunked AES-256-GCM with authenticated chunk metadata. File name, size, hash and timing remain observable over local HTTP. No cloud service is used.'
    : 'The bridge did not advertise the encrypted upload protocol. Refresh the bridge before accepting files.';
  const files = status.files || [];
  const queued = files.filter((item) => ['staged', 'claimed', 'downloading'].includes(item.status)).length;
  const complete = files.filter((item) => item.status === 'completed').length;
  $('queuedCount').textContent = String(queued);
  $('completedCount').textContent = String(complete);
  $('historyCount').textContent = `${files.length} ${files.length === 1 ? 'transfer' : 'transfers'}`;
  $('receiverHeading').textContent = queued ? 'Files are coming in' : 'Ready when you are';
  $('receiverText').textContent = queued ? 'A file is waiting in the queue while Chrome handles its download.' : 'Connect your phone with the QR code to start receiving files.';
  $('receiverTitle').textContent = queued ? `${queued} ${queued === 1 ? 'file' : 'files'} in the queue` : 'Receiver is ready';
  $('receiverSubtext').textContent = queued ? 'Chrome Downloads will pick up queued files.' : 'The local bridge is reachable and listening.';
  $('receiverLiveIndicator').classList.add('online');
  $('receiverIcon').replaceChildren(icon(queued ? 'download-simple' : 'monitor'));
  $('computer-state-dot').classList.add('online');
  renderActivities(files);
}

async function refreshDashboard() {
  try {
    const status = await api('/api/status');
    renderStatus(status);
    await refreshDiscoveredDevices(false);
    if (!currentPairingUrl || Date.now() >= currentPairingExpiresAt) await loadPairing();
    $('copyLinkBtn').disabled = !currentPairingUrl;
  } catch (error) {
    setBridgeState(false, 'PC bridge offline');
    $('pcName').textContent = 'Bridge not running';
    $('lanEndpoint').textContent = 'Receiver unavailable';
    $('receiverHeading').textContent = 'Start your PC receiver';
    $('receiverText').textContent = 'Run node bridge.js from the pc-bridge folder, then refresh this dashboard.';
    $('receiverTitle').textContent = 'Waiting for the local bridge';
    $('receiverSubtext').textContent = 'No files can be received until the PC service is running.';
    $('computer-state-dot').classList.remove('online');
    $('receiverIcon').replaceChildren(icon('monitor'));
    $('rotateBtn').disabled = true;
    $('copyLinkBtn').disabled = true;
    $('pairingUrl').textContent = error.message;
    setPairingState('Bridge offline', 'error');
    setQrPlaceholder('Bridge offline');
    $('queuedCount').textContent = '—';
    $('completedCount').textContent = '—';
    $('historyCount').textContent = latestStatus?.files?.length ? `${latestStatus.files.length} transfers` : 'Waiting for bridge';
    $('receiverLiveIndicator').classList.remove('online');
    $('securityTitle').textContent = 'Bridge security status unavailable';
    $('securityText').textContent = 'Start the local PC bridge to confirm that encrypted uploads are enabled.';
    $('clearHistoryBtn').disabled = true;
    setDiscoveryState('Bridge offline', 'error');
    $('devicesCount').textContent = 'Discovery unavailable';
    showOfflineMessageIfNeeded(error);
  }
}

let lastOfflineMessage = 0;
function showOfflineMessageIfNeeded(error) {
  if (Date.now() - lastOfflineMessage > 12000) {
    $('activityShowing').textContent = 'Start the local PC bridge to load transfer history';
    lastOfflineMessage = Date.now();
  }
}

async function processOneQueuedFile() {
  if (!bridgeOnline || processLocked) return;
  processLocked = true;
  try {
    const response = await api('/api/next-download');
    const item = response.item;
    if (!item) return;
    try {
      const downloadId = await chrome.downloads.download({
        url: item.downloadUrl,
        filename: item.filename,
        conflictAction: 'uniquify',
        saveAs: false,
      });
      const mapResult = await chrome.storage.local.get({ lanviDownloadMap: {} });
      const downloadMap = mapResult.lanviDownloadMap;
      downloadMap[String(downloadId)] = { bridgeFileId: item.id, filename: item.filename };
      await chrome.storage.local.set({ lanviDownloadMap: downloadMap });
      await post('/api/mark-downloading', { id: item.id, downloadId });
      const current = await chrome.downloads.search({ id: downloadId });
      if (current[0]?.state === 'complete') await chrome.runtime.sendMessage({ type: 'LANVI_DOWNLOAD_COMPLETE', downloadId, bridgeFileId: item.id }).catch(() => {});
      if (current[0]?.state === 'interrupted') await chrome.runtime.sendMessage({ type: 'LANVI_DOWNLOAD_INTERRUPTED', downloadId, bridgeFileId: item.id, error: current[0]?.error || 'Chrome interrupted the download.' }).catch(() => {});
      showToast(`Chrome download started: ${item.filename}`);
    } catch (error) {
      await post('/api/download-result', { id: item.id, status: 'failed', error: error.message }).catch(() => {});
      showToast(`Could not start Chrome download: ${error.message}`, 'error');
    }
  } catch (error) {
    if (bridgeOnline) showToast(error.message, 'error');
  } finally {
    processLocked = false;
    await refreshDashboard();
  }
}

async function poll() {
  if (polling) return;
  polling = true;
  try { await refreshDashboard(); await processOneQueuedFile(); }
  finally { polling = false; }
}

async function refreshWithFeedback() {
  const btn = $('refreshBtn');
  btn.classList.add('is-spinning');
  btn.disabled = true;
  try {
    await refreshDashboard();
    await loadPairing();
    await processOneQueuedFile();
    showToast('Receiver status refreshed.');
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    setTimeout(() => btn.classList.remove('is-spinning'), 620);
    btn.disabled = false;
  }
}

$('refreshBtn').addEventListener('click', refreshWithFeedback);
$('refreshDevicesBtn')?.addEventListener('click', rescanDiscoveredDevices);
$('lanAddress').addEventListener('change', loadPairing);
$('rotateBtn').addEventListener('click', async () => {
  const button = $('rotateBtn');
  button.disabled = true;
  try {
    await post('/api/rotate-pairing', {});
    currentPairingUrl = '';
    await refreshDashboard();
    await loadPairing();
    showToast('A new pairing code is ready.');
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    button.disabled = !bridgeOnline;
  }
});
$('copyLinkBtn').addEventListener('click', async () => {
  if (!currentPairingUrl) return;
  try {
    await navigator.clipboard.writeText(currentPairingUrl);
    showToast('Pairing link copied to clipboard.');
  } catch {
    showToast('Clipboard access unavailable. Select the link and copy it manually.', 'error');
  }
});
$('activitySearch').addEventListener('input', () => renderActivities(latestStatus?.files || []));
$('activityFilter').addEventListener('change', () => renderActivities(latestStatus?.files || []));
$('clearHistoryBtn').addEventListener('click', async () => {
  const files = latestStatus?.files || [];
  const removable = files.filter((item) => !['staged', 'claimed', 'downloading'].includes(item.status)).length;
  if (!removable) return;
  if (!window.confirm(`Clear ${removable} finished or failed transfer record(s) from this PC's local history? Active downloads will be kept.`)) return;
  const button = $('clearHistoryBtn');
  button.disabled = true;
  try {
    await post('/api/clear-history', {});
    renderedActivityKey = '';
    await refreshDashboard();
    showToast('Local transfer history cleared.');
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    button.disabled = false;
  }
});
$('toastClose').addEventListener('click', () => $('toast').classList.remove('visible'));
document.querySelector('[data-action="refresh"]')?.addEventListener('click', refreshWithFeedback);
document.querySelectorAll('.nav-link').forEach((link) => link.addEventListener('click', () => {
  document.querySelectorAll('.nav-link').forEach((item) => item.classList.toggle('active', item === link));
}));
document.addEventListener('keydown', (event) => {
  const target = event.target;
  const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || target?.isContentEditable;
  if (event.key === '/' && !typing) { event.preventDefault(); $('activitySearch').focus(); }
  if (event.key === 'Escape' && target === $('activitySearch')) { $('activitySearch').value = ''; renderActivities(latestStatus?.files || []); $('activitySearch').blur(); }
});
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === 'LANVI_DOWNLOAD_UPDATED') { renderedActivityKey = ''; void refreshDashboard(); }
});

(async () => {
  await refreshDashboard();
  await refreshDiscoveredDevices(true);
  await processOneQueuedFile();
  setInterval(poll, 1800);
})();
