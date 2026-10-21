/*
 * Purpose: Local-only LAN upload receiver and loopback control API for Lanvi.
 * Integration: Run with `node bridge.js`; pair with the Lanvi Chrome extension.
 * Project: Lanvi | Version: 0.6.0
 * Developer attribution: Mayank Chawdhari AKA BOSS294
 * Changelog: Adds local mDNS identity advertisement/discovery and device list API while preserving encrypted chunked uploads;
 *            encrypted frame count, plaintext byte count and SHA-256 remain mandatory before staging.
 * Security boundary: file payload chunks are encrypted/authenticated; HTTP metadata remains observable.
 */
'use strict';

const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const crypto = require('node:crypto');
const { once } = require('node:events');
const { finished } = require('node:stream/promises');
const QRCode = require('./vendor/QRCode');
const QRErrorCorrectLevel = require('./vendor/QRCode/QRErrorCorrectLevel');
const { Bonjour } = require('bonjour-service');

const LAN_PORT = Number(process.env.LANVI_LAN_PORT || 8787);
const CONTROL_PORT = Number(process.env.LANVI_CONTROL_PORT || 8788);
const PAIRING_TTL_MS = 10 * 60 * 1000;
const ENCRYPTION_VERSION = 'aes-256-gcm-chunked-v1';
const ENCRYPTION_CHUNK_BYTES = 1024 * 1024;
const GCM_TAG_BYTES = 16;
const FRAME_HEADER_BYTES = 4;
const KDF_INFO = Buffer.from('lanvi-upload-aes-256-gcm-chunked-v1', 'utf8');
function positiveIntegerEnv(name, fallback, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    throw new Error(`${name} must be a positive safe integer no greater than ${maximum}.`);
  }
  return parsed;
}

const MAX_FILE_BYTES = positiveIntegerEnv('LANVI_MAX_FILE_BYTES', 5 * 1024 * 1024 * 1024);
const MAX_STAGED_BYTES = positiveIntegerEnv('LANVI_MAX_STAGED_BYTES', 10 * 1024 * 1024 * 1024);
const MAX_ACTIVE_UPLOADS = positiveIntegerEnv('LANVI_MAX_ACTIVE_UPLOADS', 2, 32);
const MAX_UPLOADS_PER_MINUTE = positiveIntegerEnv('LANVI_MAX_UPLOADS_PER_MINUTE', 30, 1000);
const AUTH_CLOCK_SKEW_MS = 2 * 60 * 1000;
const MAX_NONCES = 20000;
const DATA_DIR = process.env.LANVI_DATA_DIR || path.join(os.homedir(), '.lanvi', 'phase02');
const STAGING_DIR = path.join(DATA_DIR, 'staging');
const INDEX_FILE = path.join(DATA_DIR, 'index.json');
const DEVICE_IDENTITY_FILE = path.join(DATA_DIR, 'device-identity.json');
const MAX_HISTORY = 300;
const DISCOVERY_SERVICE_TYPE = 'lanvi';
const DISCOVERY_PROTOCOL = 'lanvi-discovery-v1';
const DISCOVERY_STALE_MS = 90_000;

const state = {
  pairingToken: crypto.randomBytes(24).toString('hex'),
  pairingExpiresAt: Date.now() + PAIRING_TTL_MS,
  files: [],
  lanServers: [],
  controlServer: null,
  hostAddresses: [],
  activeUploads: 0,
  reservedUploadBytes: 0,
  usedNonces: new Map(),
  uploadRate: new Map(),
  indexWriteQueue: Promise.resolve(),
  deviceIdentity: null,
  bonjour: null,
  mdnsPublisher: null,
  mdnsBrowser: null,
  discoveredDevices: new Map(),
  discoveryCleanupTimer: null,
  mediaCatalogSessions: new Map(),
  mediaStreamSessions: new Map(),
};

function log(message) {
  console.log(`[Lanvi Bridge] ${new Date().toISOString()} ${message}`);
}

function privateIPv4(address) {
  return /^10\./.test(address) || /^192\.168\./.test(address) || /^172\.(1[6-9]|2\d|3[01])\./.test(address) || /^169\.254\./.test(address);
}

function findIPv4Addresses() {
  const entries = [];
  for (const [name, interfaces] of Object.entries(os.networkInterfaces())) {
    for (const item of interfaces || []) {
      if (item.family === 'IPv4' && !item.internal && item.address !== '127.0.0.1' && privateIPv4(item.address)) {
        entries.push({ name, address: item.address, isPrivate: true });
      }
    }
  }
  entries.sort((a, b) => Number(b.isPrivate) - Number(a.isPrivate) || a.name.localeCompare(b.name));
  return entries;
}

function isLoopback(req) {
  const address = String(req.socket.remoteAddress || '').toLowerCase();
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function json(res, status, body) {
  if (res.destroyed || res.writableEnded) return;
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store, max-age=0',
    'Content-Length': Buffer.byteLength(payload),
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
  });
  res.end(payload);
}

function readJson(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    let bytes = 0;
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > limit) {
        reject(new Error('Request body is too large.'));
        req.destroy();
        return;
      }
      body += chunk;
    });
    req.on('end', () => {
      try { resolve(body ? JSON.parse(body) : {}); }
      catch { reject(new Error('Invalid JSON body.')); }
    });
    req.on('error', reject);
  });
}

function safeFilename(input) {
  const raw = String(input || 'lanvi-file').normalize('NFC');
  // Strip path components, terminal control codes, bidi overrides and reserved filename characters.
  let name = raw.split(/[\\/]/).pop()
    .replace(/[\x00-\x1F\x7F]/g, '')
    .replace(/[\u202A-\u202E\u2066-\u2069]/g, '')
    .replace(/[<>:"|?*]/g, '_')
    .replace(/[. ]+$/g, '')
    .trim();
  if (!name || name === '.' || name === '..') name = 'lanvi-file';
  if (name.length > 180) {
    const ext = path.extname(name).slice(0, 20);
    name = name.slice(0, 180 - ext.length) + ext;
  }
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) name = `_${name}`;
  return name;
}

function decodeFilenameHeader(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,2048}$/.test(value)) return null;
  try {
    const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
    const decoded = Buffer.from(base64, 'base64').toString('utf8');
    if (!decoded || Buffer.from(decoded, 'utf8').toString('base64url') !== value.replace(/=+$/g, '')) return null;
    return decoded;
  } catch {
    return null;
  }
}

function normalizeRemoteAddress(value) {
  const address = String(value || '').toLowerCase();
  return address.startsWith('::ffff:') ? address.slice(7) : address;
}

function isAllowedLanAddress(value) {
  const address = normalizeRemoteAddress(value);
  if (address === '127.0.0.1' || address === '::1') return true;
  return privateIPv4(address);
}

function requestHostMatches(req, bindAddress, port, loopbackOnly = false) {
  const host = String(req.headers.host || '').toLowerCase();
  const allowed = loopbackOnly
    ? new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`])
    : new Set([`${bindAddress}:${port}`, `localhost:${port}`, `127.0.0.1:${port}`]);
  return allowed.has(host);
}

function controlOriginAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true; // Node/CLI callers have no Origin; loopback is still mandatory.
  if (typeof origin !== 'string' || origin === 'null') return false;
  let parsed;
  try { parsed = new URL(origin); } catch { return false; }
  if (parsed.protocol !== 'chrome-extension:' || !/^[a-p]{32}$/.test(parsed.hostname)) return false;
  const pinnedId = String(process.env.LANVI_EXTENSION_ID || '').trim();
  return !pinnedId || parsed.hostname === pinnedId;
}

function totalStagedBytes() {
  return state.files.reduce((sum, item) => sum + (item.storagePath ? Number(item.size || 0) : 0), 0);
}

function allowUploadRate(remoteAddress) {
  const key = normalizeRemoteAddress(remoteAddress);
  const now = Date.now();
  const existing = state.uploadRate.get(key);
  if (!existing || now - existing.startedAt >= 60_000) {
    state.uploadRate.set(key, { startedAt: now, count: 1 });
    return true;
  }
  existing.count += 1;
  return existing.count <= MAX_UPLOADS_PER_MINUTE;
}

function pruneAuthNonces(now = Date.now()) {
  for (const [nonce, expiresAt] of state.usedNonces) {
    if (expiresAt <= now) state.usedNonces.delete(nonce);
  }
  if (state.usedNonces.size > MAX_NONCES) {
    const excess = state.usedNonces.size - MAX_NONCES;
    let removed = 0;
    for (const key of state.usedNonces.keys()) {
      state.usedNonces.delete(key);
      removed += 1;
      if (removed >= excess) break;
    }
  }
}

function uploadCanonical({ timestamp, nonce, filename, size, sha256, encryptionVersion, chunkSize }) {
  return [
    'POST', '/api/upload', timestamp, nonce, filename, String(size), sha256,
    encryptionVersion, String(chunkSize),
  ].join('\n');
}

function encryptedBodyLength(plaintextSize, chunkSize = ENCRYPTION_CHUNK_BYTES) {
  const chunks = Math.max(1, Math.ceil(plaintextSize / chunkSize));
  return plaintextSize + chunks * (FRAME_HEADER_BYTES + GCM_TAG_BYTES);
}

function deriveUploadKey(token, nonceHex) {
  return Buffer.from(crypto.hkdfSync(
    'sha256',
    Buffer.from(token, 'utf8'),
    Buffer.from(nonceHex, 'hex'),
    KDF_INFO,
    32,
  ));
}

function makeChunkNonce(index) {
  const nonce = Buffer.alloc(12, 0);
  nonce.writeBigUInt64BE(BigInt(index), 4);
  return nonce;
}

function chunkAad(canonical, index, plaintextLength) {
  return Buffer.from(`${canonical}\n${index}\n${plaintextLength}`, 'utf8');
}

class RequestByteReader {
  constructor(readable) {
    this.iterator = readable[Symbol.asyncIterator]();
    this.queue = [];
    this.available = 0;
  }

  async readExactly(length, allowCleanEof = false) {
    if (!Number.isSafeInteger(length) || length < 0) throw new Error('Invalid encrypted frame length.');
    if (length === 0) return Buffer.alloc(0);
    while (this.available < length) {
      const next = await this.iterator.next();
      if (next.done) {
        if (allowCleanEof && this.available === 0) return null;
        throw new Error('Encrypted upload ended before the current frame was complete.');
      }
      const chunk = Buffer.isBuffer(next.value) ? next.value : Buffer.from(next.value);
      if (chunk.length) {
        this.queue.push({ buffer: chunk, offset: 0 });
        this.available += chunk.length;
      }
    }
    const output = Buffer.allocUnsafe(length);
    let written = 0;
    while (written < length) {
      const head = this.queue[0];
      const remaining = head.buffer.length - head.offset;
      const take = Math.min(remaining, length - written);
      head.buffer.copy(output, written, head.offset, head.offset + take);
      head.offset += take;
      written += take;
      this.available -= take;
      if (head.offset === head.buffer.length) this.queue.shift();
    }
    return output;
  }

  async assertEnd() {
    const trailing = await this.readExactly(1, true);
    if (trailing !== null) throw new Error('Encrypted upload contains unexpected trailing bytes.');
  }
}

function verifyUploadSignature(req, filename, size, expectedSha256, encryptionVersion, chunkSize) {
  ensurePairingToken();
  const timestampText = String(req.headers['x-lanvi-timestamp'] || '');
  const nonce = String(req.headers['x-lanvi-nonce'] || '');
  const signature = String(req.headers['x-lanvi-signature'] || '').toLowerCase();
  const timestamp = Number(timestampText);
  const now = Date.now();
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > AUTH_CLOCK_SKEW_MS) {
    return { ok: false, status: 401, error: 'Upload authentication expired. Refresh the pairing code and retry.' };
  }
  if (!/^[a-f0-9]{32,64}$/i.test(nonce) || !/^[a-f0-9]{64}$/.test(signature)) {
    return { ok: false, status: 401, error: 'Upload authentication headers are invalid.' };
  }
  pruneAuthNonces(now);
  if (state.usedNonces.has(nonce)) {
    return { ok: false, status: 409, error: 'This upload request was already used. Retry the transfer.' };
  }
  const canonical = uploadCanonical({ timestamp: timestampText, nonce, filename, size, sha256: expectedSha256, encryptionVersion, chunkSize });
  const expected = crypto.createHmac('sha256', state.pairingToken).update(canonical, 'utf8').digest();
  const supplied = Buffer.from(signature, 'hex');
  if (supplied.length !== expected.length || !crypto.timingSafeEqual(expected, supplied)) {
    return { ok: false, status: 401, error: 'Upload authentication failed. Re-scan the current pairing code.' };
  }
  // Reserve a nonce only after the signature is valid; retain it through token lifetime.
  state.usedNonces.set(nonce, Math.min(state.pairingExpiresAt, now + PAIRING_TTL_MS));
  return { ok: true };
}

function sameToken(candidate) {
  if (typeof candidate !== 'string') return false;
  const expected = Buffer.from(state.pairingToken, 'utf8');
  const given = Buffer.from(candidate, 'utf8');
  return expected.length === given.length && crypto.timingSafeEqual(expected, given) && Date.now() < state.pairingExpiresAt;
}

function rotatePairingToken() {
  state.pairingToken = crypto.randomBytes(24).toString('hex');
  state.pairingExpiresAt = Date.now() + PAIRING_TTL_MS;
  log(`Pairing token rotated; expires at ${new Date(state.pairingExpiresAt).toISOString()}`);
}

function ensurePairingToken() {
  if (Date.now() >= state.pairingExpiresAt) rotatePairingToken();
}

function qrSvg(text) {
  const qr = new QRCode(-1, QRErrorCorrectLevel.L);
  qr.addData(text);
  qr.make();
  const count = qr.getModuleCount();
  const quiet = 4;
  const cells = [];
  for (let row = 0; row < count; row += 1) {
    for (let col = 0; col < count; col += 1) {
      if (qr.isDark(row, col)) cells.push(`M${col + quiet},${row + quiet}h1v1h-1z`);
    }
  }
  const view = count + quiet * 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${view} ${view}" role="img" aria-label="Lanvi pairing QR code" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#FFFFFF"/><path d="${cells.join('')}" fill="#0F3D26"/></svg>`;
}

function validDeviceId(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9._:-]{8,96}$/.test(value);
}

async function loadDeviceIdentity() {
  await fsp.mkdir(DATA_DIR, { recursive: true });
  try {
    const parsed = JSON.parse(await fsp.readFile(DEVICE_IDENTITY_FILE, 'utf8'));
    if (validDeviceId(parsed.deviceId) && typeof parsed.name === 'string' && parsed.name.trim()) {
      state.deviceIdentity = { deviceId: parsed.deviceId, name: parsed.name.trim().slice(0, 64) };
      return;
    }
  } catch (error) {
    if (error.code !== 'ENOENT') log(`Could not load device identity: ${error.message}`);
  }
  state.deviceIdentity = {
    deviceId: crypto.randomUUID(),
    name: String(process.env.LANVI_DEVICE_NAME || os.hostname()).trim().slice(0, 64) || 'Lanvi PC',
  };
  const temp = `${DEVICE_IDENTITY_FILE}.${process.pid}.tmp`;
  await fsp.writeFile(temp, JSON.stringify(state.deviceIdentity, null, 2), { mode: 0o600, flag: 'w' });
  await fsp.rename(temp, DEVICE_IDENTITY_FILE);
}

function normalizeDiscoveredService(service) {
  if (!service || !service.txt || typeof service.txt !== 'object') return null;
  const txt = service.txt;
  const protocol = String(txt.protocol || '');
  const deviceId = String(txt.deviceId || '');
  const deviceType = String(txt.deviceType || 'unknown').toLowerCase();
  if (protocol !== DISCOVERY_PROTOCOL || !validDeviceId(deviceId) || deviceId === state.deviceIdentity?.deviceId) return null;
  if (!['desktop', 'mobile', 'tablet'].includes(deviceType)) return null;

  const addressesFromTxt = String(txt.addresses || '').split(',').map((value) => value.trim()).filter(Boolean);
  const addressesFromService = Array.isArray(service.addresses) ? service.addresses.map(String) : [];
  const addresses = [...new Set([...addressesFromTxt, ...addressesFromService].filter(privateIPv4))];
  const rawPort = Number(service.port || txt.port || 0);
  const port = Number.isInteger(rawPort) && rawPort > 0 && rawPort <= 65535 ? rawPort : null;
  return {
    deviceId,
    name: String(txt.deviceName || service.name || 'Lanvi device').trim().slice(0, 64),
    deviceType,
    addresses,
    port,
    capabilities: String(txt.capabilities || '').slice(0, 180),
    appVersion: String(txt.appVersion || 'unknown').slice(0, 32),
    protocol,
    online: true,
    lastSeenAt: new Date().toISOString(),
    offlineAt: null,
    serviceName: String(service.name || '').slice(0, 96),
  };
}

function upsertDiscoveredService(service) {
  const device = normalizeDiscoveredService(service);
  if (!device) return;
  const previous = state.discoveredDevices.get(device.deviceId);
  if (previous) {
    device.addresses = [...new Set([...(previous.addresses || []), ...device.addresses])].filter(privateIPv4);
    device.firstSeenAt = previous.firstSeenAt || device.lastSeenAt;
  } else {
    device.firstSeenAt = device.lastSeenAt;
  }
  state.discoveredDevices.set(device.deviceId, device);
}

function markDiscoveredServiceDown(service) {
  const deviceId = String(service?.txt?.deviceId || '');
  if (!validDeviceId(deviceId)) return;
  const previous = state.discoveredDevices.get(deviceId);
  if (previous) {
    previous.online = false;
    previous.offlineAt = new Date().toISOString();
    state.discoveredDevices.set(deviceId, previous);
  }
}

function publicDiscoveredDevices() {
  const now = Date.now();
  for (const [deviceId, device] of state.discoveredDevices) {
    const offlineAt = Date.parse(device.offlineAt || '') || 0;
    if (!device.online && offlineAt && now - offlineAt > DISCOVERY_STALE_MS) state.discoveredDevices.delete(deviceId);
  }
  return [...state.discoveredDevices.values()]
    .map((device) => ({ ...device, addresses: [...(device.addresses || [])] }))
    .sort((a, b) => Number(b.online) - Number(a.online) || a.name.localeCompare(b.name));
}

function startLocalDiscovery() {
  if (!state.deviceIdentity) return;
  try {
    state.bonjour = new Bonjour({}, (error) => {
      log(`mDNS warning: ${error.message}`);
    });
    const addresses = state.hostAddresses.map((item) => item.address).filter(privateIPv4);
    state.mdnsPublisher = state.bonjour.publish({
      name: `Lanvi-${state.deviceIdentity.deviceId.slice(0, 8)}`,
      type: DISCOVERY_SERVICE_TYPE,
      port: LAN_PORT,
      txt: {
        protocol: DISCOVERY_PROTOCOL,
        deviceId: state.deviceIdentity.deviceId,
        deviceType: 'desktop',
        deviceName: state.deviceIdentity.name,
        addresses: addresses.join(',').slice(0, 220),
        capabilities: 'phone-to-pc,chrome-downloads,media-player',
        appVersion: '0.6.0',
      },
    });
    state.mdnsPublisher.on('error', (error) => log(`mDNS publish warning: ${error.message}`));
    state.mdnsBrowser = state.bonjour.find({ type: DISCOVERY_SERVICE_TYPE }, (service) => upsertDiscoveredService(service));
    state.mdnsBrowser.on('down', markDiscoveredServiceDown);
    state.mdnsBrowser.on('srv-update', upsertDiscoveredService);
    state.mdnsBrowser.on('txt-update', upsertDiscoveredService);
    state.discoveryCleanupTimer = setInterval(publicDiscoveredDevices, 15_000);
    state.discoveryCleanupTimer.unref?.();
    log(`Local device discovery advertised as ${state.deviceIdentity.name} (${state.deviceIdentity.deviceId})`);
  } catch (error) {
    log(`Local device discovery unavailable: ${error.message}`);
  }
}

async function stopLocalDiscovery() {
  if (state.discoveryCleanupTimer) clearInterval(state.discoveryCleanupTimer);
  state.discoveryCleanupTimer = null;
  try { state.mdnsBrowser?.stop?.(); } catch {}
  try { await new Promise((resolve) => state.bonjour?.unpublishAll?.(() => resolve()) ?? resolve()); } catch {}
  try { state.bonjour?.destroy?.(); } catch {}
  state.mdnsPublisher = null;
  state.mdnsBrowser = null;
  state.bonjour = null;
}

function saveIndex() {
  const snapshot = JSON.stringify({ files: state.files.slice(-MAX_HISTORY) }, null, 2);
  const writeSnapshot = async () => {
    await fsp.mkdir(DATA_DIR, { recursive: true });
    const temp = `${INDEX_FILE}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
    try {
      await fsp.writeFile(temp, snapshot, { mode: 0o600, flag: 'wx' });
      await fsp.rename(temp, INDEX_FILE);
    } finally {
      await fsp.rm(temp, { force: true }).catch(() => {});
    }
  };
  state.indexWriteQueue = state.indexWriteQueue.then(writeSnapshot, writeSnapshot);
  return state.indexWriteQueue;
}

async function loadIndex() {
  await fsp.mkdir(STAGING_DIR, { recursive: true });
  const validStoragePaths = new Set();
  try {
    const parsed = JSON.parse(await fsp.readFile(INDEX_FILE, 'utf8'));
    const existing = Array.isArray(parsed.files) ? parsed.files : [];
    const restored = [];
    for (const candidate of existing.slice(-MAX_HISTORY)) {
      if (!candidate || typeof candidate !== 'object' || !/^[0-9a-f-]{36}$/i.test(String(candidate.id || ''))) continue;
      const item = { ...candidate };
      item.filename = safeFilename(item.filename);
      item.size = Number.isSafeInteger(Number(item.size)) && Number(item.size) >= 0 ? Number(item.size) : 0;
      if (!/^[a-f0-9]{64}$/i.test(String(item.sha256 || ''))) item.sha256 = null;
      if (!['staged', 'claimed', 'downloading', 'completed', 'interrupted', 'failed'].includes(item.status)) item.status = 'failed';
      if (item.status === 'claimed' || item.status === 'downloading') item.status = 'staged';

      const expectedPath = path.join(STAGING_DIR, `${item.id}.bin`);
      if (item.storagePath) {
        const resolved = path.resolve(String(item.storagePath));
        if (resolved !== path.resolve(expectedPath)) {
          item.storagePath = null;
          item.status = 'failed';
          item.error = 'Unsafe staging reference was rejected during recovery.';
        } else {
          try {
            const stat = await fsp.lstat(expectedPath);
            if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Not a regular file');
            item.size = stat.size;
            validStoragePaths.add(path.basename(expectedPath));
          } catch {
            item.storagePath = null;
            item.status = 'failed';
            item.error = 'Staged file was missing after restart.';
          }
        }
      }
      if (item.storagePath && !/^[a-f0-9]{48}$/i.test(String(item.downloadToken || ''))) {
        item.downloadToken = crypto.randomBytes(24).toString('hex');
      }
      restored.push(item);
    }
    state.files = restored;
  } catch (error) {
    if (error.code !== 'ENOENT') log(`Could not load history: ${error.message}`);
    state.files = [];
  }

  // Remove orphaned and partial files left by a previous crash.
  for (const entry of await fsp.readdir(STAGING_DIR, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    // .part files are decrypted staging-in-progress and are never recoverable after restart.
    if (entry.name.endsWith('.part')) {
      await fsp.rm(path.join(STAGING_DIR, entry.name), { force: true }).catch(() => {});
      continue;
    }
    if (!entry.name.endsWith('.bin')) continue;
    if (!validStoragePaths.has(entry.name)) {
      await fsp.rm(path.join(STAGING_DIR, entry.name), { force: true }).catch(() => {});
    }
  }
  await saveIndex();
}

function publicFile(item) {
  return {
    id: item.id,
    filename: item.filename,
    size: item.size,
    sha256: item.sha256,
    status: item.status,
    receivedAt: item.receivedAt,
    completedAt: item.completedAt || null,
    downloadId: item.downloadId || null,
    error: item.error || null,
    encryption: item.encryption || null,
  };
}

function mobileTestPage() {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><meta name="referrer" content="no-referrer"><title>Lanvi · Local transfer</title>
<style>
:root{color-scheme:light;--green:#0F3D26;--black:#000;--white:#fff;--line:#e1e5e2;--muted:#626963;--surface:#f6f7f6}*{box-sizing:border-box}body{margin:0;background:var(--white);color:var(--black);font-family:Inter,"Work Sans",system-ui,-apple-system,sans-serif}.wrap{width:min(100% - 32px,560px);margin:0 auto;padding:32px 0 48px}.brand{display:flex;gap:12px;align-items:center;margin-bottom:32px}.mark{width:40px;height:40px;border:1px solid var(--line);border-radius:12px;display:grid;place-items:center;color:var(--green);font-size:26px;font-weight:600}.brand strong{font-size:19px;letter-spacing:.14em}.eyebrow{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);font-weight:650}h1{font-size:clamp(28px,7vw,40px);line-height:1.1;letter-spacing:-.04em;margin:12px 0}p{color:var(--muted);line-height:1.55}.panel{border:1px solid var(--line);border-radius:20px;padding:24px;margin-top:24px}.field{display:block;border:1px dashed #a7b0aa;border-radius:14px;padding:24px 16px;text-align:center;background:var(--surface);margin:16px 0}.field input{width:100%;margin-top:12px}button{border:0;border-radius:12px;min-height:48px;background:var(--black);color:white;font-weight:650;padding:0 20px;width:100%;font-size:15px}button:disabled{opacity:.45}.note{font-size:12px;padding:12px;border-radius:10px;background:#f6f7f6;color:#414740}.status{margin-top:16px;font-size:14px;white-space:pre-wrap;overflow-wrap:anywhere}.bar{height:5px;background:#e5e9e6;border-radius:9px;overflow:hidden;margin-top:12px}.bar>span{display:block;height:100%;width:0;background:var(--green);transition:width .15s}@media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style></head><body><main class="wrap"><div class="brand"><div class="mark">L</div><strong>LANVI</strong></div><div class="eyebrow">Private local transfer</div><h1>Send a file to your PC.</h1><p>This temporary browser sender encrypts every upload chunk with AES-256-GCM. If this browser does not provide Web Crypto on the local HTTP origin, use the Lanvi Android app to send files.</p><section class="panel"><label for="files"><strong>Choose images or documents (64 MB max per file on this temporary page)</strong></label><label class="field" for="files">Select one or more files<input id="files" type="file" multiple></label><button id="send" disabled>Send encrypted to PC</button><div class="bar"><span id="bar"></span></div><div id="status" class="status" aria-live="polite">Checking encrypted-transfer support…</div></section><p class="note"><strong>Encryption:</strong> file payloads use chunked AES-256-GCM with authenticated chunk metadata. File name, size, hash and timing remain visible to observers on this HTTP local network. No cloud service is used.</p></main><script>
'use strict';
const params = new URLSearchParams(location.hash.replace(/^#/,''));
const token = params.get('token') || '';
const input = document.getElementById('files');
const send = document.getElementById('send');
const statusEl = document.getElementById('status');
const bar = document.getElementById('bar');
const encoder = new TextEncoder();
const MAX_TEST_BYTES = 64 * 1024 * 1024;
const CHUNK_SIZE = 1024 * 1024;
const ENC_VERSION = 'aes-256-gcm-chunked-v1';
const KDF_INFO = encoder.encode('lanvi-upload-aes-256-gcm-chunked-v1');
let sending = false;
function fmt(bytes){if(bytes<1024)return bytes+' B';const units=['KB','MB','GB','TB'];let n=bytes/1024,i=0;while(n>=1024&&i<units.length-1){n/=1024;i++}return n.toFixed(1)+' '+units[i]}
function toHex(bytes){return Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('')}
function randomHex(length){const bytes=crypto.getRandomValues(new Uint8Array(length));return toHex(bytes)}
function decodeHex(hex){return Uint8Array.from(hex.match(/.{2}/g)||[],v=>parseInt(v,16))}
function filenameB64Url(value){const bytes=encoder.encode(value);let binary='';for(const b of bytes)binary+=String.fromCharCode(b);return btoa(binary).replace(/=/g,'').replace(/\\+/g,'-').replace(/\\//g,'_')}
async function sha256(bytes){return toHex(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)))}
async function makeHmac(keyText, message){const key=await crypto.subtle.importKey('raw',encoder.encode(keyText),{name:'HMAC',hash:'SHA-256'},false,['sign']);return toHex(new Uint8Array(await crypto.subtle.sign('HMAC',key,encoder.encode(message))))}
async function deriveAesKey(tokenText, nonceHex){const baseKey=await crypto.subtle.importKey('raw',encoder.encode(tokenText),'HKDF',false,['deriveKey']);return crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:decodeHex(nonceHex),info:KDF_INFO},baseKey,{name:'AES-GCM',length:256},false,['encrypt'])}
function chunkIv(index){const iv=new Uint8Array(12);new DataView(iv.buffer).setBigUint64(4,BigInt(index),false);return iv}
function makeCanonical(timestamp, nonce, filename, size, hash){return ['POST','/api/upload',timestamp,nonce,filename,String(size),hash,ENC_VERSION,String(CHUNK_SIZE)].join('\\n')}
function encryptedBodyLength(size){const chunks=Math.max(1,Math.ceil(size/CHUNK_SIZE));return size+chunks*20}
async function encryptFrames(file, key, canonical){const source=new Uint8Array(await file.arrayBuffer());const chunks=Math.max(1,Math.ceil(source.length/CHUNK_SIZE));const frames=[];for(let i=0;i<chunks;i++){const start=i*CHUNK_SIZE;const plain=source.slice(start,Math.min(source.length,start+CHUNK_SIZE));const aad=encoder.encode(canonical+'\\n'+i+'\\n'+plain.length);const cipherAndTag=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:chunkIv(i),additionalData:aad,tagLength:128},key,plain));const frame=new Uint8Array(4+cipherAndTag.length);new DataView(frame.buffer).setUint32(0,cipherAndTag.length,false);frame.set(cipherAndTag,4);frames.push(frame);bar.style.width=Math.round(((i+1)/chunks)*30)+'%';statusEl.textContent='Encrypting '+file.name+' · chunk '+(i+1)+'/'+chunks;}const output=new Uint8Array(encryptedBodyLength(source.length));let offset=0;for(const frame of frames){output.set(frame,offset);offset+=frame.length;}return output}
input.addEventListener('change',()=>{send.disabled=!input.files.length||sending;statusEl.textContent=input.files.length?(input.files.length+' file(s) selected.'):'Select files to begin.'});
if(!token){statusEl.textContent='Pairing token is missing. Open the current QR code with Lanvi and scan it again.';send.disabled=true}
else if(!crypto.subtle){statusEl.textContent='This browser does not expose Web Crypto for this local HTTP origin. Use the Lanvi Android app to send encrypted files. No unencrypted fallback is provided.';send.disabled=true}
else statusEl.textContent='Encrypted transfer is available. Choose a test file.';
send.addEventListener('click',async()=>{if(!token||!crypto.subtle){statusEl.textContent='Use the Lanvi app for authenticated encrypted transfer from this local network.';return}if(!input.files.length||sending)return;sending=true;send.disabled=true;const files=Array.from(input.files);let done=0;for(const file of files){if(file.size>MAX_TEST_BYTES){statusEl.textContent='The temporary browser page supports files up to 64 MB. Use Lanvi Android for larger files.';break}try{statusEl.textContent='Preparing '+file.name+' ('+fmt(file.size)+')…';bar.style.width='0%';const source=new Uint8Array(await file.arrayBuffer());const hash=await sha256(source);const timestamp=String(Date.now());const nonce=randomHex(24);const canonical=makeCanonical(timestamp,nonce,file.name,file.size,hash);const signature=await makeHmac(token,canonical);const key=await deriveAesKey(token,nonce);const encrypted=await encryptFrames(file,key,canonical);bar.style.width='50%';const response=await fetch('/api/upload',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Lanvi-Timestamp':timestamp,'X-Lanvi-Nonce':nonce,'X-Lanvi-Filename-B64':filenameB64Url(file.name),'X-Lanvi-Size':String(file.size),'X-Lanvi-SHA256':hash,'X-Lanvi-Encryption':ENC_VERSION,'X-Lanvi-Chunk-Size':String(CHUNK_SIZE),'X-Lanvi-Signature':signature},body:encrypted,cache:'no-store',referrerPolicy:'no-referrer'});const result=await response.json().catch(()=>({error:'The bridge returned an unreadable response.'}));if(!response.ok)throw new Error(result.error||('HTTP '+response.status));done++;bar.style.width=Math.round((done/files.length)*100)+'%';statusEl.textContent='Encrypted and received: '+done+'/'+files.length+'\\n'+file.name+'\\nSize: '+fmt(result.size)+'\\nSHA-256: '+result.sha256;}catch(error){statusEl.textContent='Transfer failed for '+file.name+': '+error.message;break}}if(done===files.length){statusEl.textContent='All '+done+' file(s) encrypted, verified and sent to the PC. Keep the receiver dashboard open for Chrome Downloads.';input.value=''}sending=false;send.disabled=!input.files.length});
</script></body></html>`;
}

async function handleUpload(req, res, requestUrl) {
  const remoteAddress = normalizeRemoteAddress(req.socket.remoteAddress);
  if (!isAllowedLanAddress(remoteAddress)) {
    req.resume();
    return json(res, 403, { error: 'Lanvi accepts uploads only from a private local network.' });
  }
  if (!allowUploadRate(remoteAddress)) {
    req.resume();
    return json(res, 429, { error: 'Too many upload requests. Wait a minute and try again.' });
  }
  if (state.activeUploads >= MAX_ACTIVE_UPLOADS) {
    req.resume();
    return json(res, 429, { error: 'The receiver is busy. Retry after another transfer finishes.' });
  }

  const encodedFilename = req.headers['x-lanvi-filename-b64'];
  const rawFilename = decodeFilenameHeader(encodedFilename);
  if (rawFilename === null) {
    req.resume();
    return json(res, 400, { error: 'A valid base64url-encoded UTF-8 filename header is required.' });
  }
  if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/octet-stream')) {
    req.resume();
    return json(res, 415, { error: 'File uploads must use application/octet-stream.' });
  }

  const encryptionVersion = String(req.headers['x-lanvi-encryption'] || '');
  const chunkSize = Number(req.headers['x-lanvi-chunk-size']);
  if (encryptionVersion !== ENCRYPTION_VERSION || chunkSize !== ENCRYPTION_CHUNK_BYTES) {
    req.resume();
    return json(res, 415, { error: `Encrypted uploads must use ${ENCRYPTION_VERSION} with ${ENCRYPTION_CHUNK_BYTES}-byte chunks. Unencrypted uploads are rejected.` });
  }

  const declaredSize = Number(req.headers['x-lanvi-size']);
  const expectedSha256 = String(req.headers['x-lanvi-sha256'] || '').toLowerCase();
  if (!Number.isSafeInteger(declaredSize) || declaredSize < 0) {
    req.resume();
    return json(res, 400, { error: 'A valid X-Lanvi-Size header is required.' });
  }
  if (declaredSize > MAX_FILE_BYTES) {
    req.resume();
    return json(res, 413, { error: `File exceeds the configured ${MAX_FILE_BYTES} byte limit.` });
  }
  if (!/^[a-f0-9]{64}$/.test(expectedSha256)) {
    req.resume();
    return json(res, 400, { error: 'A valid SHA-256 digest is required.' });
  }
  const nonce = String(req.headers['x-lanvi-nonce'] || '');
  if (!/^[a-f0-9]{48}$/i.test(nonce)) {
    req.resume();
    return json(res, 400, { error: 'A valid 24-byte upload nonce is required for key derivation.' });
  }

  let expectedBodyLength;
  try { expectedBodyLength = encryptedBodyLength(declaredSize, chunkSize); }
  catch { expectedBodyLength = -1; }

  // Flutter's streamed HTTP client may use Transfer-Encoding: chunked when the
  // request length is intentionally unknown. In that case, HTTP framing is
  // validated by Node, and the encrypted frame reader below verifies the exact
  // number and size of application frames before a file can be staged.
  const rawContentLength = req.headers['content-length'];
  const contentLength = rawContentLength === undefined ? null : Number(rawContentLength);
  const transferEncodings = String(req.headers['transfer-encoding'] || '')
    .split(',').map((value) => value.trim().toLowerCase()).filter(Boolean);
  const isChunkedBody = contentLength === null && transferEncodings.includes('chunked');
  const hasExactContentLength = contentLength !== null &&
    Number.isSafeInteger(contentLength) && contentLength === expectedBodyLength;

  if (!Number.isSafeInteger(expectedBodyLength) || expectedBodyLength < 0 ||
      (!hasExactContentLength && !isChunkedBody)) {
    req.resume();
    return json(res, 400, {
      error: 'The HTTP body framing is inconsistent with the encrypted file size.',
      expectedEncryptedBodyBytes: expectedBodyLength,
      receivedContentLength: contentLength,
      transferEncoding: transferEncodings.join(',') || null,
      hint: 'Retry with the updated Lanvi app, which streams encrypted frames using chunked HTTP transfer encoding.',
    });
  }
  if (totalStagedBytes() + state.reservedUploadBytes + declaredSize > MAX_STAGED_BYTES) {
    req.resume();
    return json(res, 507, { error: 'The Lanvi staging quota is full. Complete or clear staged downloads and retry.' });
  }

  const auth = verifyUploadSignature(req, rawFilename, declaredSize, expectedSha256, encryptionVersion, chunkSize);
  if (!auth.ok) {
    req.resume();
    return json(res, auth.status, { error: auth.error });
  }

  state.activeUploads += 1;
  state.reservedUploadBytes += declaredSize;
  const id = crypto.randomUUID();
  const tempStoragePath = path.join(STAGING_DIR, `${id}.part`);
  const storagePath = path.join(STAGING_DIR, `${id}.bin`);
  let output;
  try {
    const filename = safeFilename(rawFilename);
    const key = deriveUploadKey(state.pairingToken, nonce);
    const canonical = uploadCanonical({
      timestamp: String(req.headers['x-lanvi-timestamp']),
      nonce,
      filename: rawFilename,
      size: declaredSize,
      sha256: expectedSha256,
      encryptionVersion,
      chunkSize,
    });
    const chunkCount = Math.max(1, Math.ceil(declaredSize / chunkSize));
    const reader = new RequestByteReader(req);
    output = fs.createWriteStream(tempStoragePath, { flags: 'wx', mode: 0o600 });
    const hash = crypto.createHash('sha256');
    let plaintextSize = 0;

    for (let index = 0; index < chunkCount; index += 1) {
      const header = await reader.readExactly(FRAME_HEADER_BYTES);
      const framedLength = header.readUInt32BE(0);
      const expectedPlainLength = declaredSize === 0 ? 0 : Math.min(chunkSize, declaredSize - plaintextSize);
      const expectedFrameLength = expectedPlainLength + GCM_TAG_BYTES;
      if (framedLength !== expectedFrameLength) throw new Error('Encrypted chunk length did not match its expected frame.');

      const frame = await reader.readExactly(framedLength);
      const ciphertext = frame.subarray(0, expectedPlainLength);
      const tag = frame.subarray(expectedPlainLength);
      const decipher = crypto.createDecipheriv('aes-256-gcm', key, makeChunkNonce(index), { authTagLength: GCM_TAG_BYTES });
      decipher.setAAD(chunkAad(canonical, index, expectedPlainLength));
      decipher.setAuthTag(tag);
      let plaintext;
      try {
        plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      } catch {
        throw new Error(`Encrypted chunk ${index + 1} failed AES-GCM authentication. No file will be staged.`);
      }
      if (plaintext.length !== expectedPlainLength) throw new Error('Decrypted chunk length does not match the declared size.');
      plaintextSize += plaintext.length;
      if (plaintext.length) {
        hash.update(plaintext);
        if (!output.write(plaintext)) await once(output, 'drain');
      }
    }
    await reader.assertEnd();
    if (plaintextSize !== declaredSize) throw new Error('The decrypted byte count does not match the declared file size.');
    output.end();
    await finished(output);
    output = null;

    const actualSha256 = hash.digest('hex');
    if (!crypto.timingSafeEqual(Buffer.from(actualSha256, 'hex'), Buffer.from(expectedSha256, 'hex'))) {
      throw new Error('SHA-256 verification failed after decryption. No file was staged.');
    }

    await fsp.rename(tempStoragePath, storagePath);
    const item = {
      id, filename, size: plaintextSize, sha256: actualSha256, status: 'staged',
      receivedAt: new Date().toISOString(), storagePath,
      downloadToken: crypto.randomBytes(24).toString('hex'),
      encryption: ENCRYPTION_VERSION,
    };
    state.files.push(item);
    while (state.files.length > MAX_HISTORY) {
      const pruneIndex = state.files.findIndex((candidate) => !['staged', 'claimed', 'downloading'].includes(candidate.status));
      if (pruneIndex < 0) break;
      const [pruned] = state.files.splice(pruneIndex, 1);
      if (pruned.storagePath) await fsp.rm(pruned.storagePath, { force: true }).catch(() => {});
    }
    await saveIndex();
    log(`Staged encrypted upload ${filename} (${plaintextSize} bytes; AES-256-GCM; SHA-256 ${actualSha256})`);
    return json(res, 201, { id, filename, size: plaintextSize, sha256: actualSha256, status: 'staged', encryption: ENCRYPTION_VERSION });
  } catch (error) {
    if (output) {
      output.destroy();
      await finished(output).catch(() => {});
    }
    await fsp.rm(tempStoragePath, { force: true }).catch(() => {});
    await fsp.rm(storagePath, { force: true }).catch(() => {});
    log(`Encrypted upload rejected: ${error.message}`);
    if (!res.headersSent && !res.destroyed) {
      const invalidTag = /AES-GCM authentication|SHA-256 verification|Decrypted byte count|chunk length/i.test(error.message);
      return json(res, invalidTag ? 422 : 400, {
        error: invalidTag ? error.message : 'Encrypted upload did not finish cleanly. Please retry.',
      });
    }
  } finally {
    state.activeUploads = Math.max(0, state.activeUploads - 1);
    state.reservedUploadBytes = Math.max(0, state.reservedUploadBytes - declaredSize);
  }
}

function handleLanRequest(req, res, bindAddress) {
  if (!isAllowedLanAddress(req.socket.remoteAddress)) {
    req.resume();
    return json(res, 403, { error: 'Lanvi only accepts private-network connections.' });
  }
  if (!requestHostMatches(req, bindAddress, LAN_PORT)) {
    req.resume();
    return json(res, 421, { error: 'Unexpected Host header.' });
  }
  const requestUrl = new URL(req.url, 'http://lanvi.local');
  if (req.method === 'GET' && requestUrl.pathname === '/health') {
    return json(res, 200, { service: 'lanvi-lan-receiver', status: 'online', port: LAN_PORT });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/mobile-test') {
    const body = mobileTestPage();
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, max-age=0',
      'Content-Length': Buffer.byteLength(body),
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    });
    return res.end(body);
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/upload') return void handleUpload(req, res, requestUrl);
  req.resume();
  return json(res, 404, { error: 'Not found. This LAN endpoint only accepts the temporary mobile test page and authenticated file uploads.' });
}


const MEDIA_CHUNK_BYTES = 1024 * 1024;
const MEDIA_SESSION_TTL_MS = 3 * 60 * 60 * 1000;
const MEDIA_CATALOG_TTL_MS = 30 * 60 * 1000;
const MEDIA_GCM_TAG_BYTES = 16;

function hmacSha256Hex(secret, message) {
  return crypto.createHmac('sha256', String(secret)).update(message, 'utf8').digest('hex');
}

function constantTimeHexEqual(expectedHex, suppliedHex) {
  if (!/^[a-f0-9]{64}$/i.test(String(expectedHex)) || !/^[a-f0-9]{64}$/i.test(String(suppliedHex))) return false;
  const expected = Buffer.from(expectedHex, 'hex');
  const supplied = Buffer.from(suppliedHex, 'hex');
  return expected.length === supplied.length && crypto.timingSafeEqual(expected, supplied);
}

function mediaResponseCanonical(timestamp, nonce, status, body) {
  const bodyHash = crypto.createHash('sha256').update(body).digest('hex');
  return ['LANVI-MEDIA-RESPONSE', timestamp, nonce, String(status), bodyHash].join('\n');
}

function pruneMediaSessions() {
  const now = Date.now();
  for (const [id, session] of state.mediaCatalogSessions) if (session.expiresAt <= now) state.mediaCatalogSessions.delete(id);
  for (const [id, session] of state.mediaStreamSessions) if (session.expiresAt <= now) state.mediaStreamSessions.delete(id);
}

function mediaTargetForDevice(deviceId) {
  const device = state.discoveredDevices.get(String(deviceId || ''));
  if (!device || !device.online || device.deviceType !== 'mobile') return null;
  const capabilities = String(device.capabilities || '').split(',').map((value) => value.trim());
  if (!capabilities.includes('media-library') || !validDeviceId(device.deviceId)) return null;
  const address = (device.addresses || []).find(privateIPv4);
  const port = Number(device.port);
  if (!address || !Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { deviceId: device.deviceId, name: device.name, address, port, addresses: device.addresses, appVersion: device.appVersion || 'unknown' };
}

async function requestPhoneMedia(target, token, requestPath) {
  const timestamp = String(Date.now());
  const nonce = crypto.randomBytes(24).toString('hex');
  const requesterDeviceId = state.deviceIdentity?.deviceId || '';
  if (!validDeviceId(requesterDeviceId)) throw new Error('The PC device identity is unavailable. Restart the Lanvi bridge.');
  const canonical = ['GET', requestPath, timestamp, nonce, requesterDeviceId].join('\n');
  const signature = hmacSha256Hex(token, canonical);
  const url = `http://${target.address}:${target.port}${requestPath}`;
  const response = await fetch(url, {
    method: 'GET',
    cache: 'no-store',
    signal: AbortSignal.timeout(20000),
    headers: {
      'Accept': 'application/json, application/octet-stream',
      'X-Lanvi-Timestamp': timestamp,
      'X-Lanvi-Nonce': nonce,
      'X-Lanvi-Signature': signature,
      'X-Lanvi-Requester-Device-Id': requesterDeviceId,
    },
  });
  const body = Buffer.from(await response.arrayBuffer());
  if (!response.ok) {
    let detail = '';
    try { detail = JSON.parse(body.toString('utf8')).error || ''; } catch {}
    if (response.status === 403 && /disabled/i.test(detail)) {
      throw new Error('Media sharing is disabled on the phone. Open Lanvi → Media and enable media sharing.');
    }
    if (response.status === 401 || response.status === 403) {
      throw new Error(detail || 'The phone rejected this media request. Scan the current PC QR code on the phone, then enable media sharing.');
    }
    throw new Error(detail || `Phone media endpoint returned HTTP ${response.status}.`);
  }
  const responseSignature = String(response.headers.get('x-lanvi-response-signature') || '').toLowerCase();
  const expectedSignature = hmacSha256Hex(token, mediaResponseCanonical(timestamp, nonce, response.status, body));
  if (!constantTimeHexEqual(expectedSignature, responseSignature)) {
    throw new Error('Phone media response authentication failed. The response may have been modified on the local network.');
  }
  return { body, timestamp, nonce, status: response.status };
}

function decryptPhoneMediaChunk(session, requestNonce, index, encryptedBody) {
  if (encryptedBody.length < MEDIA_GCM_TAG_BYTES) throw new Error('Encrypted media chunk is incomplete.');
  const offset = index * MEDIA_CHUNK_BYTES;
  const expectedPlainBytes = Math.min(MEDIA_CHUNK_BYTES, session.size - offset);
  if (expectedPlainBytes <= 0) throw new Error('Requested media chunk is outside the file.');
  const expectedFrameLength = expectedPlainBytes + MEDIA_GCM_TAG_BYTES;
  if (encryptedBody.length !== expectedFrameLength) throw new Error(`Encrypted media frame length mismatch (${encryptedBody.length} / ${expectedFrameLength}).`);
  const salt = Buffer.concat([Buffer.from(session.sessionId, 'hex'), Buffer.from(requestNonce, 'hex')]);
  const info = Buffer.from(`lanvi-media-aes-256-gcm-v1:${session.mediaId}:${index}`, 'utf8');
  const key = Buffer.from(crypto.hkdfSync('sha256', Buffer.from(session.token, 'utf8'), salt, info, 32));
  const iv = Buffer.alloc(12, 0);
  iv.writeBigUInt64BE(BigInt(index), 4);
  const aad = Buffer.from(`lanvi-media-chunk-v1\n${session.pcDeviceId}\n${session.mediaId}\n${session.size}\n${session.sessionId}\n${index}\n${expectedPlainBytes}\n${requestNonce}`, 'utf8');
  const tag = encryptedBody.subarray(encryptedBody.length - MEDIA_GCM_TAG_BYTES);
  const ciphertext = encryptedBody.subarray(0, encryptedBody.length - MEDIA_GCM_TAG_BYTES);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  if (plain.length !== expectedPlainBytes) throw new Error('Decrypted media chunk length mismatch.');
  return plain;
}

async function fetchPhoneMediaChunk(session, index) {
  const requestPath = `/api/media/chunk?mediaId=${encodeURIComponent(session.mediaId)}&sessionId=${encodeURIComponent(session.sessionId)}&index=${index}`;
  const response = await requestPhoneMedia(session.target, session.token, requestPath);
  return decryptPhoneMediaChunk(session, response.nonce, index, response.body);
}

async function streamPhoneMedia(req, res, session) {
  const size = Number(session.size);
  if (!Number.isSafeInteger(size) || size <= 0) return json(res, 416, { error: 'This media file has an invalid size.' });
  let start = 0;
  let end = size - 1;
  let partial = false;
  const rangeHeader = String(req.headers.range || '');
  if (rangeHeader) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
    if (!match || (!match[1] && !match[2])) {
      res.writeHead(416, { 'Content-Range': `bytes */${size}`, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' });
      return res.end();
    }
    if (!match[1]) {
      const suffix = Number(match[2]);
      if (!Number.isSafeInteger(suffix) || suffix <= 0) {
        res.writeHead(416, { 'Content-Range': `bytes */${size}`, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' });
        return res.end();
      }
      start = Math.max(0, size - suffix);
    } else {
      start = Number(match[1]);
      end = match[2] ? Number(match[2]) : size - 1;
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || start >= size) {
      res.writeHead(416, { 'Content-Range': `bytes */${size}`, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' });
      return res.end();
    }
    end = Math.min(end, size - 1);
    partial = true;
  }
  const responseLength = end - start + 1;
  const mimeType = /^(audio|video)\/[a-z0-9.+-]+$/i.test(String(session.mimeType || '')) ? session.mimeType : 'application/octet-stream';
  const headers = {
    'Content-Type': mimeType,
    'Content-Length': responseLength,
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store, max-age=0',
    'X-Content-Type-Options': 'nosniff',
    'Content-Disposition': `inline; filename="${String(session.filename || 'lanvi-media').replace(/[^\x20-\x7E]/g, '_').replace(/["\\\r\n]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(String(session.filename || 'lanvi-media'))}`,
  };
  if (partial) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
  if (req.method === 'HEAD') {
    res.writeHead(partial ? 206 : 200, headers);
    return res.end();
  }

  const firstIndex = Math.floor(start / MEDIA_CHUNK_BYTES);
  const lastIndex = Math.floor(end / MEDIA_CHUNK_BYTES);
  let firstChunk;
  try {
    firstChunk = await fetchPhoneMediaChunk(session, firstIndex);
  } catch (error) {
    return json(res, 502, { error: `Could not retrieve encrypted media from the phone: ${error.message}` });
  }
  if (res.destroyed) return;
  res.writeHead(partial ? 206 : 200, headers);

  for (let index = firstIndex; index <= lastIndex; index += 1) {
    let plain;
    if (index === firstIndex) plain = firstChunk;
    else {
      try { plain = await fetchPhoneMediaChunk(session, index); }
      catch (error) { log(`Media stream ${session.sessionId} failed on chunk ${index}: ${error.message}`); res.destroy(error); return; }
    }
    const chunkStart = index * MEDIA_CHUNK_BYTES;
    const localStart = Math.max(0, start - chunkStart);
    const localEnd = Math.min(plain.length, end - chunkStart + 1);
    if (localEnd > localStart) {
      if (!res.write(plain.subarray(localStart, localEnd))) await once(res, 'drain');
    }
    if (res.destroyed) return;
  }
  res.end();
}

async function handleMediaCatalog(req, res, requestUrl) {
  pruneMediaSessions();
  ensurePairingToken();
  const deviceId = requestUrl.searchParams.get('deviceId') || '';
  const target = mediaTargetForDevice(deviceId);
  if (!target) return json(res, 404, { error: 'No online Lanvi phone with media-library capability was found. Keep Lanvi open on the phone and refresh discovery.' });
  try {
    const remote = await requestPhoneMedia(target, state.pairingToken, '/api/media/catalog');
    let catalog;
    try { catalog = JSON.parse(remote.body.toString('utf8')); } catch { throw new Error('The phone returned an invalid media catalog.'); }
    if (!catalog || catalog.protocol !== 'lanvi-media-v1' || catalog.deviceId !== target.deviceId || !Array.isArray(catalog.items)) {
      throw new Error('The discovered phone returned an incompatible media catalog.');
    }
    const items = catalog.items.filter((item) => item && /^[a-f0-9]{32}$/.test(String(item.id || '')) &&
      Number.isSafeInteger(Number(item.size)) && Number(item.size) > 0 &&
      ['music', 'video'].includes(String(item.kind)) && /^(audio|video)\//i.test(String(item.mimeType || '')))
      .slice(0, 3000).map((item) => ({
        id: String(item.id), name: String(item.name || 'Media file').slice(0, 240),
        relativePath: String(item.relativePath || item.name || 'Media file').slice(0, 500),
        folder: String(item.folder || '').slice(0, 500), kind: String(item.kind), mimeType: String(item.mimeType),
        size: Number(item.size), modifiedAt: String(item.modifiedAt || ''),
      }));
    const catalogSessionId = crypto.randomBytes(32).toString('hex');
    const session = { sessionId: catalogSessionId, target, token: state.pairingToken, pcDeviceId: state.deviceIdentity.deviceId, deviceId: target.deviceId, deviceName: target.name, items: new Map(items.map((item) => [item.id, item])), expiresAt: Date.now() + MEDIA_CATALOG_TTL_MS };
    state.mediaCatalogSessions.set(catalogSessionId, session);
    return json(res, 200, { protocol: 'lanvi-media-catalog-v1', sessionId: catalogSessionId, device: { deviceId: target.deviceId, name: target.name, address: target.address }, items });
  } catch (error) {
    log(`Media catalog request failed for ${target.name}: ${error.message}`);
    return json(res, 502, { error: error.message || 'Unable to read the phone media library.' });
  }
}

async function handleMediaOpen(req, res) {
  let body;
  try { body = await readJson(req); } catch (error) { return json(res, 400, { error: error.message }); }
  pruneMediaSessions();
  const catalogSession = state.mediaCatalogSessions.get(String(body.catalogSessionId || ''));
  if (!catalogSession || catalogSession.expiresAt <= Date.now()) return json(res, 410, { error: 'The media library session expired. Refresh the phone media list.' });
  const item = catalogSession.items.get(String(body.mediaId || ''));
  if (!item) return json(res, 404, { error: 'The selected media item is no longer in the phone catalog.' });
  if (item.size > MAX_FILE_BYTES) return json(res, 413, { error: `This media file exceeds the configured streaming limit of ${MAX_FILE_BYTES} bytes.` });
  const sessionId = crypto.randomBytes(32).toString('hex');
  const session = {
    sessionId, token: catalogSession.token, pcDeviceId: catalogSession.pcDeviceId,
    target: catalogSession.target, deviceId: catalogSession.deviceId, deviceName: catalogSession.deviceName,
    mediaId: item.id, filename: item.name, mimeType: item.mimeType, kind: item.kind, size: item.size,
    expiresAt: Date.now() + MEDIA_SESSION_TTL_MS,
  };
  state.mediaStreamSessions.set(sessionId, session);
  return json(res, 200, {
    sessionId, filename: item.name, mimeType: item.mimeType, kind: item.kind, size: item.size,
    streamUrl: `http://127.0.0.1:${CONTROL_PORT}/api/media/stream/${sessionId}`,
    expiresAt: new Date(session.expiresAt).toISOString(),
  });
}

function handleControlRequest(req, res) {
  if (!isLoopback(req)) return json(res, 403, { error: 'Control API is available only from this PC.' });
  if (!requestHostMatches(req, '127.0.0.1', CONTROL_PORT, true)) return json(res, 421, { error: 'Unexpected Host header.' });
  if (!controlOriginAllowed(req)) return json(res, 403, { error: 'Browser-origin requests are allowed only from the Lanvi Chrome extension.' });
  if (req.method === 'POST' && !String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) {
    req.resume();
    return json(res, 415, { error: 'Control POST requests must use application/json.' });
  }
  const requestUrl = new URL(req.url, `http://127.0.0.1:${CONTROL_PORT}`);
  if (req.method === 'GET' && requestUrl.pathname === '/api/status') {
    ensurePairingToken();
    const counts = state.files.reduce((acc, item) => { acc[item.status] = (acc[item.status] || 0) + 1; return acc; }, {});
    return json(res, 200, {
      service: 'lanvi-control', status: 'online', lanPort: LAN_PORT, controlPort: CONTROL_PORT,
      transportSecurity: { payloadEncryption: ENCRYPTION_VERSION, chunkSize: ENCRYPTION_CHUNK_BYTES, metadataEncrypted: false },
      pcName: state.deviceIdentity?.name || os.hostname(),
      ownDevice: state.deviceIdentity ? { ...state.deviceIdentity, deviceType: 'desktop', port: LAN_PORT, addresses: state.hostAddresses.map((item) => item.address) } : null,
      addresses: state.hostAddresses,
      pairingExpiresAt: new Date(state.pairingExpiresAt).toISOString(), pairingExpiresInMs: Math.max(0, state.pairingExpiresAt - Date.now()),
      counts, files: state.files.slice(-80).reverse().map(publicFile), maxFileBytes: MAX_FILE_BYTES,
    });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/api/pairing') {
    ensurePairingToken();
    const host = requestUrl.searchParams.get('host') || state.hostAddresses[0]?.address;
    if (!host || !state.hostAddresses.some((item) => item.address === host)) return json(res, 400, { error: 'Choose a LAN IPv4 address shown by the bridge.' });
    const pairingExpiresAt = new Date(state.pairingExpiresAt).toISOString();
    const fragment = new URLSearchParams({ token: state.pairingToken, deviceId: state.deviceIdentity?.deviceId || '', deviceName: state.deviceIdentity?.name || os.hostname(), expiresAt: pairingExpiresAt }).toString();
    const pairingUrl = `http://${host}:${LAN_PORT}/mobile-test#${fragment}`;
    return json(res, 200, { pairingUrl, expiresAt: pairingExpiresAt, deviceId: state.deviceIdentity?.deviceId || null, deviceName: state.deviceIdentity?.name || os.hostname(), qrSvg: qrSvg(pairingUrl) });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/api/devices') {
    return json(res, 200, {
      protocol: DISCOVERY_PROTOCOL,
      scanning: Boolean(state.mdnsBrowser),
      ownDevice: state.deviceIdentity ? {
        deviceId: state.deviceIdentity.deviceId,
        name: state.deviceIdentity.name,
        deviceType: 'desktop',
        port: LAN_PORT,
        addresses: state.hostAddresses.map((item) => ({ address: item.address, name: item.name })),
      } : null,
      devices: publicDiscoveredDevices(),
      authorizationNote: 'Discovery only identifies devices advertising Lanvi. It does not authorize file transfer; pair devices with the current QR code.',
    });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/api/media/targets') {
    pruneMediaSessions();
    const targets = publicDiscoveredDevices()
      .filter((device) => device.online && device.deviceType === 'mobile')
      .map((device) => ({
        deviceId: device.deviceId,
        name: device.name,
        deviceType: device.deviceType,
        online: device.online,
        addresses: device.addresses,
        port: device.port,
        capabilities: device.capabilities,
        appVersion: device.appVersion,
        mediaAvailable: String(device.capabilities || '').split(',').map((value) => value.trim()).includes('media-library'),
      }));
    return json(res, 200, { protocol: DISCOVERY_PROTOCOL, targets });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/api/media/catalog') {
    return void handleMediaCatalog(req, res, requestUrl);
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/media/open') {
    return void handleMediaOpen(req, res);
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/media/close') {
    return void readJson(req).then((body) => {
      const id = String(body.sessionId || '');
      const removed = state.mediaStreamSessions.delete(id);
      return json(res, 200, { ok: true, closed: removed });
    }).catch((error) => json(res, 400, { error: error.message }));
  }
  if ((req.method === 'GET' || req.method === 'HEAD') && requestUrl.pathname.startsWith('/api/media/stream/')) {
    pruneMediaSessions();
    const id = requestUrl.pathname.split('/').pop();
    const session = state.mediaStreamSessions.get(id);
    if (!session || !/^[a-f0-9]{64}$/.test(id || '')) return json(res, 404, { error: 'The media stream session expired. Reopen the media item.' });
    return void streamPhoneMedia(req, res, session).catch((error) => {
      log(`Media stream failed: ${error.message}`);
      if (!res.headersSent && !res.destroyed) json(res, 502, { error: error.message });
      else if (!res.destroyed) res.destroy(error);
    });
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/discovery/refresh') {
    try { state.mdnsBrowser?.update?.(); } catch (error) { return json(res, 503, { error: `Discovery refresh failed: ${error.message}` }); }
    return json(res, 202, { ok: true, scanning: Boolean(state.mdnsBrowser) });
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/rotate-pairing') {
    rotatePairingToken();
    return json(res, 200, { expiresAt: new Date(state.pairingExpiresAt).toISOString() });
  }
  if (req.method === 'GET' && requestUrl.pathname === '/api/next-download') {
    const now = Date.now();
    for (const item of state.files) {
      if (item.status === 'claimed' && item.claimedAt && now - item.claimedAt > 120000) item.status = 'staged';
    }
    const requestedId = requestUrl.searchParams.get('id');
    const item = state.files.find((candidate) => candidate.status === 'staged' && (!requestedId || candidate.id === requestedId));
    if (!item) return json(res, 200, { item: null });
    item.status = 'claimed'; item.claimedAt = now;
    saveIndex().catch((error) => log(`Could not save claim: ${error.message}`));
    return json(res, 200, { item: { ...publicFile(item), downloadUrl: `http://127.0.0.1:${CONTROL_PORT}/api/download/${item.id}?token=${item.downloadToken}` } });
  }
  if (req.method === 'GET' && requestUrl.pathname.startsWith('/api/download/')) {
    const id = requestUrl.pathname.split('/').pop();
    const item = state.files.find((candidate) => candidate.id === id);
    if (!item || !item.storagePath || requestUrl.searchParams.get('token') !== item.downloadToken || !['claimed', 'downloading'].includes(item.status)) return json(res, 404, { error: 'The staged download is not available.' });
    fs.stat(item.storagePath, (statError, stat) => {
      if (statError) return json(res, 404, { error: 'The staged file is missing.' });
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': stat.size,
        'Content-Disposition': `attachment; filename="${item.filename.replace(/[^\x20-\x7E]/g, '_').replace(/["\r\n]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(item.filename)}`,
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      });
      const stream = fs.createReadStream(item.storagePath);
      stream.on('error', (error) => { log(`File stream failed: ${error.message}`); if (!res.headersSent) res.writeHead(500); res.destroy(); });
      stream.pipe(res);
    });
    return;
  }
  if (req.method === 'POST' && ['/api/mark-downloading', '/api/release-download', '/api/download-result', '/api/retry'].includes(requestUrl.pathname)) {
    return void readJson(req).then(async (body) => {
      const item = state.files.find((candidate) => candidate.id === body.id);
      if (!item) return json(res, 404, { error: 'Transfer not found.' });
      if (requestUrl.pathname === '/api/mark-downloading') {
        item.status = 'downloading'; item.downloadId = Number(body.downloadId); item.claimedAt = Date.now();
      } else if (requestUrl.pathname === '/api/release-download') {
        item.status = 'staged'; item.error = String(body.error || 'Chrome could not start the download.').slice(0, 300); delete item.claimedAt;
      } else if (requestUrl.pathname === '/api/download-result') {
        const nextStatus = body.status === 'interrupted' ? 'interrupted' : 'failed';
        item.status = nextStatus; item.error = String(body.error || 'Chrome download was interrupted.').slice(0, 300); item.downloadId = Number(body.downloadId || item.downloadId || 0);
      } else {
        if (!['interrupted', 'failed'].includes(item.status)) return json(res, 409, { error: 'Only interrupted or failed transfers can be retried.' });
        item.status = 'staged'; item.error = null; delete item.claimedAt; delete item.downloadId;
      }
      await saveIndex();
      return json(res, 200, { ok: true, item: publicFile(item) });
    }).catch((error) => json(res, 400, { error: error.message }));
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/ack') {
    return void readJson(req).then(async (body) => {
      const item = state.files.find((candidate) => candidate.id === body.id);
      if (!item) return json(res, 404, { error: 'Transfer not found.' });
      if (body.status === 'complete') {
        item.status = 'completed'; item.completedAt = new Date().toISOString(); item.error = null;
        if (item.storagePath) { await fsp.rm(item.storagePath, { force: true }).catch(() => {}); delete item.storagePath; }
        delete item.downloadToken; delete item.claimedAt;
      } else {
        item.status = 'interrupted'; item.error = String(body.error || 'Chrome download was interrupted.').slice(0, 300);
      }
      await saveIndex();
      log(`Download ${item.filename}: ${item.status}`);
      return json(res, 200, { ok: true, item: publicFile(item) });
    }).catch((error) => json(res, 400, { error: error.message }));
  }
  if (req.method === 'POST' && requestUrl.pathname === '/api/clear-history') {
    return void (async () => {
      for (const item of state.files) if (item.storagePath && item.status !== 'staged' && item.status !== 'claimed' && item.status !== 'downloading') await fsp.rm(item.storagePath, { force: true }).catch(() => {});
      state.files = state.files.filter((item) => ['staged', 'claimed', 'downloading'].includes(item.status));
      await saveIndex();
      return json(res, 200, { ok: true });
    })();
  }
  return json(res, 404, { error: 'Unknown local control endpoint.' });
}

async function main() {
  await loadIndex();
  await loadDeviceIdentity();
  state.hostAddresses = findIPv4Addresses();
  // Bind only to loopback and local/private addresses. Never bind to 0.0.0.0.
  const bindAddresses = ['127.0.0.1', ...state.hostAddresses.map((item) => item.address)];
  state.lanServers = bindAddresses.map((address) => http.createServer((req, res) => handleLanRequest(req, res, address)));
  state.lanServers.forEach((server) => {
    server.requestTimeout = 30 * 60 * 1000;
    server.headersTimeout = 15 * 1000;
    server.keepAliveTimeout = 5 * 1000;
    server.maxHeadersCount = 40;
  });
  state.controlServer = http.createServer(handleControlRequest);
  state.controlServer.requestTimeout = 30 * 1000;
  state.controlServer.headersTimeout = 10 * 1000;
  state.controlServer.keepAliveTimeout = 5 * 1000;
  state.controlServer.maxHeadersCount = 40;
  await Promise.all([
    ...state.lanServers.map((server, index) => new Promise((resolve, reject) => {
      server.once('error', reject).listen(LAN_PORT, bindAddresses[index], resolve);
    })),
    new Promise((resolve, reject) => state.controlServer.once('error', reject).listen(CONTROL_PORT, '127.0.0.1', resolve)),
  ]);
  for (const address of bindAddresses) log(`LAN receiver listening on ${address}:${LAN_PORT}`);
  startLocalDiscovery();
  log(`Control API listening on 127.0.0.1:${CONTROL_PORT} (loopback only)`);
  log(`Local data directory: ${DATA_DIR}`);
  log(`Upload protections: HMAC-SHA256 auth, replay protection, AES-256-GCM chunked payload encryption, ${MAX_ACTIVE_UPLOADS} concurrent uploads, ${MAX_FILE_BYTES} bytes per file, ${MAX_STAGED_BYTES} bytes staged quota.`);
  log('Transport note: file payloads are encrypted/authenticated; upload metadata remains visible over local HTTP. No cloud services are used.');
  if (!state.hostAddresses.length) log('WARNING: No LAN IPv4 address found. Connect PC to Wi-Fi/Ethernet and restart the bridge.');
  else for (const item of state.hostAddresses) log(`Possible phone-reachable address: ${item.address} (${item.name})`);
  log(`Pairing token expires in ${PAIRING_TTL_MS / 60000} minutes. Open the Lanvi Receiver extension to show the QR code.`);
  log('Device discovery is local mDNS only. Discovered devices are not trusted until explicitly paired.');
  log('Phone media streaming uses authenticated requests and AES-256-GCM encrypted chunks; decrypted bytes are exposed only on this PC loopback player endpoint.');
}

async function shutdown() {
  log('Stopping...');
  await stopLocalDiscovery();
  for (const server of state.lanServers) server.close();
  state.controlServer?.close();
  process.exit(0);
}
process.on('SIGINT', () => { void shutdown(); });
process.on('SIGTERM', () => { void shutdown(); });
main().catch((error) => { console.error(`[Lanvi Bridge] Fatal: ${error.stack || error.message}`); process.exit(1); });
