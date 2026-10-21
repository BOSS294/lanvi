# Lanvi

Lanvi is a **no-AI, local-network file sharing project**. It pairs an Android phone with a PC using a temporary QR code, then sends files directly across the local network. The repository contains a Flutter mobile app, a Node.js receiver, and a Chrome extension that manages the PC's downloads.

Lanvi does not include AI features, call an AI API, or require an AI account or API key. Some optional presentation features can use the internet: seeded profile avatars are fetched from DiceBear, and selected Google Fonts may be downloaded by the `google_fonts` package. Those are separate from file transfer. The receiver and transfer flow are designed for a reachable local network and do not use a cloud relay.

## Features

- Pair a phone to the PC receiver by scanning a short-lived QR code, with a manual link option if scanning is unavailable.
- Send one or multiple files from the Android file picker, or share files to Lanvi from another Android app.
- Encrypt file payloads in independently authenticated AES-256-GCM chunks, authenticate upload metadata with HMAC-SHA256, reject replayed requests, and verify the completed file's SHA-256 before staging it.
- View transfer history and integrity results on the phone; browse nearby Lanvi devices on the local network.
- Optionally enable phone media-library access and stream supported audio or video to the Chrome extension while the phone app is running.
- Save completed PC downloads through Chrome Downloads and manage staged transfers in the receiver dashboard.
- Customize the app profile, theme, and typography.

Media access is opt-in and requires the relevant Android permission. Chrome's supported audio and video codecs determine which media can play.

## How the pieces fit together

```text
Android phone (Lanvi) ── encrypted LAN transfer ──> Node.js PC bridge
          │                                           │
          └──── optional encrypted media stream ──────┤
                                                      └── Chrome extension → Chrome Downloads
```

The bridge exposes a LAN receiver (default port `8787`) and a separate loopback-only control API (default port `8788`) for the extension. The control API is bound to `127.0.0.1`; it is not intended to be reachable from other devices. The phone and PC must be able to reach each other on the same local network. Guest Wi-Fi isolation, VPN routing, or firewall rules may prevent pairing or transfers.

## Requirements

- Flutter SDK compatible with Dart `>=3.11.0 <4.0.0` (see `pubspec.yaml`).
- Android Studio / Android SDK for building and running the Android app.
- Node.js 20 or later for the PC bridge.
- Google Chrome for the receiver extension and download workflow.
- A phone and PC on a mutually reachable local network.

The app is Android-first: QR pairing, Android share intents, and media-library permissions are implemented for Android. Flutter project folders for other platforms are present, but the full receiver workflow described here requires the Android app and Chrome extension.

## Install and run

### 1. Start the PC bridge

From the repository root:

```bash
cd pc-bridge
npm ci
npm start
```

Keep this terminal open. On first startup the bridge creates a fresh temporary pairing token and prints receiver information. Transfer files are staged under `~/.lanvi/phase02` by default (on Windows, under the current user's home directory). The bridge also writes local receiver identity and transfer state there. This directory is runtime data and is excluded from Git.

Optional bridge settings are read from environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `LANVI_LAN_PORT` | `8787` | Phone-facing local-network receiver port |
| `LANVI_CONTROL_PORT` | `8788` | Loopback-only extension control port |
| `LANVI_DATA_DIR` | `~/.lanvi/phase02` | Receiver state and staged files directory |
| `LANVI_MAX_FILE_BYTES` | 5 GiB | Maximum size for one received file |
| `LANVI_MAX_STAGED_BYTES` | 10 GiB | Maximum total staged file size |
| `LANVI_MAX_ACTIVE_UPLOADS` | `2` | Concurrent upload limit |
| `LANVI_MAX_UPLOADS_PER_MINUTE` | `30` | Upload rate limit |

On Windows, allow Node.js through Windows Defender Firewall on **Private networks** if prompted. Do not expose the bridge ports to the public internet.

### 2. Load the Chrome extension

1. In Chrome, open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Select **Load unpacked** and choose this repository's `chrome-extension` folder.
4. Open the Lanvi extension and launch its receiver dashboard.
5. Confirm that the dashboard reports the local bridge as online and shows a current pairing QR code.

If Chrome is configured with multiple profiles, load the extension in the profile you intend to use for downloads. The extension uses Chrome's Downloads API, so received files are saved to the location configured in Chrome.

### 3. Build and run the Android app

In a second terminal at the repository root:

```bash
flutter pub get
flutter run
```

Choose a connected Android device or emulator. A real phone and PC on the same reachable Wi-Fi network are needed for LAN transfers; an emulator may not be able to reach a PC using the addresses advertised on the network.

### 4. Pair and send a file

1. Keep the bridge running and open the Chrome receiver dashboard.
2. In Lanvi, choose **Connect your PC** and scan the dashboard QR code. If scanning is unavailable, copy the current pairing link from the dashboard and paste it into the app.
3. Approve camera access when prompted for QR scanning. Pairing tokens expire; scan the currently displayed QR if a pairing has expired.
4. Choose **Send files**, select files, and start the transfer. You can also use Android's Share action in another app and select Lanvi.
5. Watch transfer status in Lanvi and the receiver dashboard. The extension sends completed files to Chrome Downloads.

To stream media, open the media section in Lanvi and explicitly enable media sharing. Grant audio/video access when Android asks. Keep Lanvi running while using the media player in the Chrome dashboard.

## Build an Android release

```bash
flutter build apk --release
```

Flutter writes the APK under `build/app/outputs/flutter-apk/`. For Play Store distribution, configure the Android package identity and signing credentials for your own release before building an app bundle:

```bash
flutter build appbundle --release
```

Do not commit signing keys, keystores, passwords, or generated release binaries.

## Development commands

Run these from the repository root unless noted:

```bash
flutter analyze
flutter test
```

For the bridge (from `pc-bridge`):

```bash
npm run check
npm run smoke
```

The smoke command expects a running bridge. See `chrome-extension/README.md` for extension details and the transfer security boundary.

## Security and privacy notes

- File contents sent by the Android app are encrypted with AES-256-GCM chunking. The bridge authenticates upload metadata with HMAC-SHA256, checks for replay, and verifies the plaintext SHA-256 before making a file available to Chrome.
- Encryption protects the file payload. LAN HTTP metadata (including filenames, sizes, device/network addresses, and timing) is not encrypted by TLS. Treat this as a trusted-private-network tool, not an internet-facing server.
- The QR code contains a temporary pairing token. Only scan or paste it into your own trusted Lanvi phone, and refresh it if it may have been exposed.
- The bridge's staged files, pairing/device state, and history are stored locally in the configured data directory. The app stores its profile, pairing, preferences, and history on the device.
- LAN discovery uses local multicast DNS. Discovery advertises presence; it does not grant transfer access. Pairing is still required.
- Core file transfer does not depend on a cloud service. Optional seeded avatars use DiceBear over HTTPS, and Google Fonts may fetch font files when selected. No AI service is included.

## Repository layout

```text
lib/                 Flutter application and LAN services
Assets/              Lanvi logo and app artwork
android/             Android host project
ios/, macos/,        Other Flutter platform host projects
linux/, windows/, web/
pc-bridge/           Node.js LAN receiver and control API
chrome-extension/    Chrome Manifest V3 receiver dashboard
```

## License

No license file is currently included. Ask the project owner for permission before redistributing or using this project beyond the rights granted by its applicable assets and dependencies.
