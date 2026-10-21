# Lanvi Chrome Extension

Lanvi's Manifest V3 receiver dashboard runs in Chrome and coordinates downloads through the loopback-only PC bridge. It uses local APIs only; no external CDN or cloud service is required.

## Transfer security

The PC bridge requires the `aes-256-gcm-chunked-v1` upload protocol. Each file is transferred as independently authenticated AES-256-GCM chunks; HMAC-SHA256 authenticates request metadata and prevents replay. The bridge decrypts each chunk locally, verifies the full plaintext SHA-256, and only then exposes the staged file to Chrome Downloads.

HTTP metadata such as the filename, size, expected hash, IP address and timing is still observable on the local network. File payload bytes are encrypted. This is not TLS and does not encrypt every HTTP header. The receiver is intended for a trusted local network. No cloud services, signalling, storage or relay are used.

## Install / update

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Use Load unpacked (first installation) or Reload (after updating).
4. Open the Lanvi popup and launch the receiver dashboard.
5. Start the bridge with `node bridge.js` from the `pc-bridge` directory and generate a fresh pairing QR.

The dashboard checks the bridge protocol advertised by its loopback status endpoint and displays the current encryption status.
