/*
 * Purpose: Verify encrypted LAN upload, AES-GCM tag validation, HMAC authentication, replay resistance and Chrome staging.
 * Integration: Start bridge.js, then run `node smoke-test.js` from this directory.
 * Project: Lanvi | Version: 0.4.0 | Developer attribution: Mayank Chawdhari AKA BOSS294
 */
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

const LAN = process.env.LANVI_TEST_LAN_URL || 'http://127.0.0.1:8787';
const CONTROL = process.env.LANVI_TEST_CONTROL_URL || 'http://127.0.0.1:8788';
const ENC_VERSION = 'aes-256-gcm-chunked-v1';
const CHUNK_SIZE = 1024 * 1024;
const TAG_BYTES = 16;
const FRAME_BYTES = 4;
const KDF_INFO = Buffer.from('lanvi-upload-aes-256-gcm-chunked-v1', 'utf8');

async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => ({}));
  return { response, body };
}

function canonicalUpload({ timestamp, nonce, filename, size, sha256 }) {
  return ['POST', '/api/upload', timestamp, nonce, filename, String(size), sha256, ENC_VERSION, String(CHUNK_SIZE)].join('\n');
}

function deriveKey(token, nonce) {
  return Buffer.from(crypto.hkdfSync('sha256', Buffer.from(token, 'utf8'), Buffer.from(nonce, 'hex'), KDF_INFO, 32));
}

function makeIv(index) {
  const iv = Buffer.alloc(12, 0);
  iv.writeBigUInt64BE(BigInt(index), 4);
  return iv;
}

function encryptBody(token, nonce, canonical, bytes) {
  const count = Math.max(1, Math.ceil(bytes.length / CHUNK_SIZE));
  const key = deriveKey(token, nonce);
  const frames = [];
  for (let index = 0; index < count; index += 1) {
    const start = index * CHUNK_SIZE;
    const plain = bytes.subarray(start, Math.min(bytes.length, start + CHUNK_SIZE));
    const aad = Buffer.from(`${canonical}\n${index}\n${plain.length}`, 'utf8');
    const cipher = crypto.createCipheriv('aes-256-gcm', key, makeIv(index), { authTagLength: TAG_BYTES });
    cipher.setAAD(aad);
    const encrypted = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
    const header = Buffer.alloc(FRAME_BYTES);
    header.writeUInt32BE(encrypted.length, 0);
    frames.push(header, encrypted);
  }
  return Buffer.concat(frames);
}

function signedHeaders(token, filename, bytes, options = {}) {
  const timestamp = String(Date.now());
  const nonce = options.nonce || crypto.randomBytes(24).toString('hex');
  const sha256 = options.sha256 || crypto.createHash('sha256').update(bytes).digest('hex');
  const canonical = canonicalUpload({ timestamp, nonce, filename, size: bytes.length, sha256 });
  const signature = crypto.createHmac('sha256', token).update(canonical, 'utf8').digest('hex');
  const body = encryptBody(token, nonce, canonical, bytes);
  return {
    body,
    sha256,
    nonce,
    signature,
    headers: {
      'Content-Type': 'application/octet-stream',
      'X-Lanvi-Timestamp': timestamp,
      'X-Lanvi-Nonce': nonce,
      'X-Lanvi-Filename-B64': Buffer.from(filename, 'utf8').toString('base64url'),
      'X-Lanvi-Size': String(bytes.length),
      'X-Lanvi-SHA256': sha256,
      'X-Lanvi-Encryption': ENC_VERSION,
      'X-Lanvi-Chunk-Size': String(CHUNK_SIZE),
      'X-Lanvi-Signature': signature,
    },
  };
}

async function uploadSigned(signed, body = signed.body, headerOverrides = {}) {
  return requestJson(`${LAN}/api/upload`, {
    method: 'POST',
    headers: { ...signed.headers, ...headerOverrides },
    body,
  });
}


function uploadSignedChunked(signed, body = signed.body, headerOverrides = {}) {
  const target = new URL(`${LAN}/api/upload`);
  const headers = { ...signed.headers, ...headerOverrides, 'Transfer-Encoding': 'chunked' };
  delete headers['Content-Length'];
  delete headers['content-length'];

  return new Promise((resolve, reject) => {
    const request = http.request({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: `${target.pathname}${target.search}`,
      method: 'POST',
      headers,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
      response.on('error', reject);
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let bodyJson = {};
        try { bodyJson = text ? JSON.parse(text) : {}; } catch {}
        resolve({
          response: {
            status: response.statusCode,
            statusCode: response.statusCode,
            ok: response.statusCode >= 200 && response.statusCode < 300,
          },
          body: bodyJson,
        });
      });
    });
    request.on('error', reject);

    // Split the framed body across writes to ensure the server handles multiple
    // HTTP chunks independently from the AES-GCM application frames.
    const boundary = Math.min(37_123, body.length);
    if (boundary > 0) request.write(body.subarray(0, boundary));
    request.end(body.subarray(boundary));
  });
}

async function main() {
  const statusResult = await requestJson(`${CONTROL}/api/status`);
  if (!statusResult.response.ok || statusResult.body.status !== 'online') {
    throw new Error('Local bridge is not online. Start node bridge.js first.');
  }
  if (statusResult.body.transportSecurity?.payloadEncryption !== ENC_VERSION) {
    throw new Error('Bridge status does not advertise the expected encrypted payload protocol.');
  }

  // Phase 05: the bridge must expose a stable local identity and discovery state.
  const devicesResult = await requestJson(`${CONTROL}/api/devices`);
  if (!devicesResult.response.ok || devicesResult.body.protocol !== 'lanvi-discovery-v1') {
    throw new Error('The local device discovery API is unavailable or has the wrong protocol.');
  }
  if (!devicesResult.body.ownDevice?.deviceId || devicesResult.body.ownDevice?.deviceType !== 'desktop') {
    throw new Error('The bridge does not expose a stable desktop device identity.');
  }
  if (!Array.isArray(devicesResult.body.devices)) {
    throw new Error('The local discovered-devices response must be an array.');
  }
  const mediaTargetsResult = await requestJson(`${CONTROL}/api/media/targets`);
  if (!mediaTargetsResult.response.ok || mediaTargetsResult.body.protocol !== 'lanvi-discovery-v1' || !Array.isArray(mediaTargetsResult.body.targets)) {
    throw new Error('The local media target API is unavailable or has an invalid response.');
  }
  const refreshDiscovery = await requestJson(`${CONTROL}/api/discovery/refresh`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
  });
  if (refreshDiscovery.response.status !== 202 || refreshDiscovery.body.ok !== true) {
    throw new Error(`Discovery refresh was not accepted: ${refreshDiscovery.response.status}.`);
  }
  const host = statusResult.body.addresses[0]?.address;
  if (!host) throw new Error('The bridge did not detect a LAN IPv4 address.');

  const pairingResult = await requestJson(`${CONTROL}/api/pairing?host=${encodeURIComponent(host)}`);
  if (!pairingResult.response.ok) throw new Error(pairingResult.body.error || 'Could not generate a pairing URL.');
  const pairingUrl = new URL(pairingResult.body.pairingUrl);
  const fragmentParameters = new URLSearchParams(pairingUrl.hash.slice(1));
  const token = fragmentParameters.get('token');
  if (!token) throw new Error('The pairing token must be in the URL fragment, not the query string.');
  if (!fragmentParameters.get('deviceId') || !fragmentParameters.get('deviceName') || !fragmentParameters.get('expiresAt')) {
    throw new Error('The pairing URL should include device identity and token expiry in its fragment.');
  }
  if (pairingUrl.searchParams.has('token')) throw new Error('Security regression: token appeared in the URL query string.');

  const sourceName = `../lanvi-security-${Date.now()}-测试.txt`;
  const expectedSafeName = sourceName.split(/[\\/]/).pop();
  const source = Buffer.concat([
    Buffer.from(`Lanvi encrypted security smoke test\nRequest: ${crypto.randomUUID()}\nUnicode: ✓\n`, 'utf8'),
    crypto.randomBytes(CHUNK_SIZE + 37),
  ]);

  // The bridge must reject an unencrypted legacy upload instead of silently falling back.
  const legacy = await requestJson(`${LAN}/api/upload`, {
    method: 'POST', headers: {
      'Content-Type': 'application/octet-stream',
      'X-Lanvi-Filename-B64': Buffer.from('plaintext.txt').toString('base64url'),
      'X-Lanvi-Size': String(source.length),
      'X-Lanvi-SHA256': crypto.createHash('sha256').update(source).digest('hex'),
    }, body: source,
  });
  if (legacy.response.status !== 415) throw new Error(`Unencrypted upload must be rejected with 415; got ${legacy.response.status}.`);

  const validSigned = signedHeaders(token, sourceName, source);

  // Wrong HMAC is rejected before decryption or staging.
  const invalid = await uploadSigned(validSigned, validSigned.body, { 'X-Lanvi-Signature': '0'.repeat(64) });
  if (invalid.response.status !== 401) throw new Error(`Invalid HMAC should return 401, got ${invalid.response.status}.`);

  // Tamper with ciphertext; GCM authentication must fail and nothing may be staged.
  const badCiphertext = Buffer.from(validSigned.body);
  badCiphertext[FRAME_BYTES + Math.min(5, Math.max(0, source.length - 1))] ^= 0x01;
  const tampered = await uploadSigned(validSigned, badCiphertext);
  if (tampered.response.status !== 422) throw new Error(`Tampered encrypted content should return 422, got ${tampered.response.status}: ${tampered.body.error || ''}`);

  // Encrypted plaintext whose actual digest differs from the signed digest must not be staged.
  const wrongHashSigned = signedHeaders(token, 'wrong-hash.txt', source, { sha256: '0'.repeat(64) });
  const wrongHash = await uploadSigned(wrongHashSigned);
  if (wrongHash.response.status !== 422) throw new Error(`Signed hash mismatch should return 422, got ${wrongHash.response.status}.`);

  // Valid upload.
  const upload = signedHeaders(token, sourceName, source);
  // Flutter now sends streamed encrypted frames with HTTP chunked transfer
  // encoding. Verify that path end-to-end (not just known Content-Length).
  const uploaded = await uploadSignedChunked(upload);
  if (uploaded.response.status !== 201) throw new Error(`Valid encrypted upload returned ${uploaded.response.status}: ${uploaded.body.error || 'unknown error'}`);
  if (uploaded.body.size !== source.length || uploaded.body.sha256 !== upload.sha256 || uploaded.body.encryption !== ENC_VERSION) {
    throw new Error('Upload-side size, encryption marker or SHA-256 does not match the source.');
  }
  if (uploaded.body.filename !== expectedSafeName || /[\\/]/.test(uploaded.body.filename)) {
    throw new Error(`Unsafe filename was not sanitized correctly: ${uploaded.body.filename}`);
  }

  // Reusing an authenticated nonce must be rejected.
  const replay = await uploadSigned(upload);
  if (replay.response.status !== 409) throw new Error(`Replayed nonce should return 409, got ${replay.response.status}.`);

  // A browser origin other than the extension must not access local control state.
  const csrf = await requestJson(`${CONTROL}/api/status`, { headers: { Origin: 'https://evil.example' } });
  if (csrf.response.status !== 403) throw new Error(`Control API should reject an untrusted Origin, got ${csrf.response.status}.`);
  const extensionOrigin = await requestJson(`${CONTROL}/api/status`, { headers: { Origin: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop' } });
  if (extensionOrigin.response.status !== 200) throw new Error(`Control API should accept a Chrome extension origin, got ${extensionOrigin.response.status}.`);

  const claim = await requestJson(`${CONTROL}/api/next-download?id=${encodeURIComponent(uploaded.body.id)}`);
  if (!claim.response.ok || !claim.body.item) throw new Error('Encrypted upload did not enter the Chrome download queue.');
  const downloadResponse = await fetch(claim.body.item.downloadUrl);
  if (!downloadResponse.ok) throw new Error(`Staged download returned HTTP ${downloadResponse.status}.`);
  const downloaded = Buffer.from(await downloadResponse.arrayBuffer());
  const downloadedHash = crypto.createHash('sha256').update(downloaded).digest('hex');
  if (downloaded.length !== source.length || downloadedHash !== upload.sha256 || !downloaded.equals(source)) {
    throw new Error('Downloaded plaintext does not match the source byte-for-byte after encrypted transfer.');
  }

  await requestJson(`${CONTROL}/api/mark-downloading`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: uploaded.body.id, downloadId: -1 }),
  });
  const ack = await requestJson(`${CONTROL}/api/ack`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: uploaded.body.id, status: 'complete' }),
  });
  if (!ack.response.ok || ack.body.item?.status !== 'completed') throw new Error('The staged download could not be acknowledged.');

  // Empty files still carry one authenticated zero-length frame.
  const emptySigned = signedHeaders(token, 'empty.txt', Buffer.alloc(0));
  const emptyUpload = await uploadSigned(emptySigned);
  if (emptyUpload.response.status !== 201 || emptyUpload.body.size !== 0) throw new Error('Empty-file encrypted transfer failed.');

  console.log('LANVI ENCRYPTED BRIDGE TEST: PASS');
  console.log('Passed: encrypted protocol required; invalid HMAC rejected; AES-GCM tamper rejected; signed SHA mismatch rejected; replay rejected; extension-origin guard; media target API shape; chunked HTTP encrypted payload decrypted and staged byte-for-byte; exact-length empty-file upload; Chrome queue.');
  console.log(`Filename: ${uploaded.body.filename}`);
  console.log(`Bytes: ${source.length}`);
  console.log(`SHA-256: ${upload.sha256}`);
  console.log('Note: payload bytes are encrypted/authenticated. Request metadata remains observable on local HTTP. No cloud services used.');
}

main().catch((error) => {
  console.error(`LANVI ENCRYPTED BRIDGE TEST: FAIL\n${error.stack || error.message}`);
  process.exitCode = 1;
});
