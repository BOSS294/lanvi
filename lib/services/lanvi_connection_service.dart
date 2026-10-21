// Purpose: Pair with Lanvi PC bridge and upload files using chunked AES-256-GCM with HMAC-authenticated metadata.
// How to use: Call LanviConnectionService.instance from pairing and transfer pages.
// Project: Lanvi | Release: 1.6.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds streaming framed AES-256-GCM upload protocol matching the Node bridge; retains SHA-256 verification and rate metrics.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'lanvi_device_registry_service.dart';

class LanviPairing {
  const LanviPairing({
    required this.host,
    required this.port,
    required this.token,
    required this.scannedAt,
    this.deviceId,
    this.deviceName,
    this.pairingExpiresAt,
  });

  final String host;
  final int port;
  final String token;
  final DateTime scannedAt;
  final String? deviceId;
  final String? deviceName;
  final DateTime? pairingExpiresAt;

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);

  factory LanviPairing.fromQr(String rawValue) {
    final uri = Uri.tryParse(rawValue.trim());
    if (uri == null || !uri.hasAuthority) {
      throw const FormatException('This is not a valid Lanvi pairing URL.');
    }
    if (uri.scheme.toLowerCase() != 'http' || uri.path != '/mobile-test') {
      throw const FormatException(
        'This QR code is not a Lanvi receiver code. Open the Lanvi Receiver dashboard on your PC and scan its current QR code.',
      );
    }

    final host = uri.host;
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4 || !_isPrivateLanAddress(host)) {
      throw const FormatException(
        'The QR code must contain the PC’s private local IPv4 address. Choose the Wi-Fi address in the Chrome extension.',
      );
    }

    // New QR codes put the pairing token in the URL fragment. Browsers do not
    // transmit fragments to the PC server, keeping the token out of request URLs
    // and common access logs. Query fallback supports older QR codes during migration.
    Map<String, String> fragmentParameters = <String, String>{};
    try {
      fragmentParameters = Uri.splitQueryString(uri.fragment);
    } on FormatException {
      fragmentParameters = <String, String>{};
    }
    final token = (fragmentParameters['token'] ?? uri.queryParameters['token'] ?? '').trim();
    if (token.isEmpty) {
      throw const FormatException('The pairing QR does not contain a token. Generate a fresh QR code on the PC.');
    }

    final port = uri.hasPort ? uri.port : 8787;
    if (port < 1 || port > 65535) {
      throw const FormatException('The receiver port in this QR code is invalid.');
    }

    return LanviPairing(
      host: host,
      port: port,
      token: token,
      scannedAt: DateTime.now(),
      deviceId: fragmentParameters['deviceId']?.trim().isNotEmpty == true ? fragmentParameters['deviceId']!.trim() : null,
      deviceName: fragmentParameters['deviceName']?.trim().isNotEmpty == true ? fragmentParameters['deviceName']!.trim() : null,
      pairingExpiresAt: DateTime.tryParse(fragmentParameters['expiresAt'] ?? ''),
    );
  }

  factory LanviPairing.fromJson(Map<String, dynamic> json) {
    final pairing = LanviPairing(
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      token: json['token'] as String,
      scannedAt: DateTime.tryParse(json['scannedAt'] as String? ?? '') ?? DateTime.now(),
      deviceId: (json['deviceId'] as String?)?.trim().isNotEmpty == true ? (json['deviceId'] as String).trim() : null,
      deviceName: (json['deviceName'] as String?)?.trim().isNotEmpty == true ? (json['deviceName'] as String).trim() : null,
      pairingExpiresAt: DateTime.tryParse(json['pairingExpiresAt'] as String? ?? ''),
    );
    final address = InternetAddress.tryParse(pairing.host);
    if (address == null || address.type != InternetAddressType.IPv4 || !_isPrivateLanAddress(pairing.host)) {
      throw const FormatException('The saved PC address is not a private IPv4 address.');
    }
    return pairing;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'host': host,
        'port': port,
        'token': token,
        'scannedAt': scannedAt.toIso8601String(),
        if (deviceId != null) 'deviceId': deviceId,
        if (deviceName != null) 'deviceName': deviceName,
        if (pairingExpiresAt != null) 'pairingExpiresAt': pairingExpiresAt!.toIso8601String(),
      };

  static bool _isPrivateLanAddress(String value) {
    final octets = value.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((part) => part == null || part < 0 || part > 255)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254) ||
        (a == 127); // Loopback is useful for development/emulators only.
  }
}

class LanviTransferReceipt {
  const LanviTransferReceipt({
    required this.id,
    required this.filename,
    required this.size,
    required this.sha256,
    required this.status,
  });

  final String id;
  final String filename;
  final int size;
  final String sha256;
  final String status;
}

class LanviIntegrityException implements Exception {
  const LanviIntegrityException({
    required this.filename,
    required this.expectedHash,
    required this.receivedHash,
    required this.size,
  });

  final String filename;
  final String expectedHash;
  final String receivedHash;
  final int size;

  @override
  String toString() =>
      'Integrity verification failed for $filename. The source and PC SHA-256 values do not match.';
}

class LanviConnectionService {
  LanviConnectionService._();

  static final LanviConnectionService instance = LanviConnectionService._();
  double? _lastUploadMegabytesPerSecond;

  double? get lastUploadMegabytesPerSecond => _lastUploadMegabytesPerSecond;

  Future<double?> loadLastUploadMegabytesPerSecond() async {
    if (_lastUploadMegabytesPerSecond != null) return _lastUploadMegabytesPerSecond;
    try {
      final preferences = await SharedPreferences.getInstance();
      _lastUploadMegabytesPerSecond = preferences.getDouble(_lastUploadRateKey);
    } catch (_) {
      // The dashboard can still fall back to the measured health-response time.
    }
    return _lastUploadMegabytesPerSecond;
  }

  static const String _pairingKey = 'lanvi.connection.pc_pairing';
  static const String _lastUploadRateKey = 'lanvi.connection.last_upload_mb_per_second';
  static const Duration _healthTimeout = Duration(seconds: 5);

  Future<void> savePairing(LanviPairing pairing) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_pairingKey, jsonEncode(pairing.toJson()));
    final identity = pairing.deviceId?.trim().isNotEmpty == true
        ? pairing.deviceId!.trim()
        : 'legacy-pc-${pairing.host.replaceAll('.', '-')}-${pairing.port}';
    await LanviDeviceRegistryService.instance.rememberPc(
      deviceId: identity,
      name: pairing.deviceName?.trim().isNotEmpty == true ? pairing.deviceName!.trim() : 'Lanvi PC',
      address: pairing.host,
      port: pairing.port,
      pairingExpiresAt: pairing.pairingExpiresAt,
    );
  }

  Future<LanviPairing?> loadPairing() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_pairingKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return LanviPairing.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPairing() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_pairingKey);
  }

  Future<bool> checkHealth(LanviPairing pairing) async {
    final client = http.Client();
    try {
      final response = await client
          .get(pairing.baseUri.replace(path: '/health'))
          .timeout(_healthTimeout);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> &&
          body['service'] == 'lanvi-lan-receiver' &&
          body['status'] == 'online';
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static const int _encryptionChunkSize = 1024 * 1024;
  static const String _encryptionVersion = 'aes-256-gcm-chunked-v1';
  static const String _kdfInfo = 'lanvi-upload-aes-256-gcm-chunked-v1';
  static const int _gcmTagBytes = 16;
  static const int _frameHeaderBytes = 4;

  String _createNonce() {
    final random = math.Random.secure();
    return List<int>.generate(24, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Uint8List _decodeHex(String hex) => Uint8List.fromList(
        List<int>.generate(hex.length ~/ 2, (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16)),
      );

  Uint8List _chunkNonce(int index) {
    final nonce = Uint8List(12); // First four bytes are a fixed domain prefix; the per-upload key is unique.
    ByteData.sublistView(nonce).setUint64(4, index, Endian.big);
    return nonce;
  }

  Future<cryptography.SecretKey> _deriveUploadKey({
    required String token,
    required String requestNonce,
  }) async {
    final hkdf = cryptography.Hkdf(
      hmac: cryptography.Hmac.sha256(),
      outputLength: 32,
    );
    return hkdf.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(token)),
      nonce: _decodeHex(requestNonce),
      info: utf8.encode(_kdfInfo),
    );
  }

  String _uploadCanonical({
    required String timestamp,
    required String nonce,
    required String filename,
    required int size,
    required String sha256,
  }) => <String>[
        'POST',
        '/api/upload',
        timestamp,
        nonce,
        filename,
        size.toString(),
        sha256,
        _encryptionVersion,
        _encryptionChunkSize.toString(),
      ].join('\n');

  Future<Uint8List> _encryptFrame({
    required List<int> plaintext,
    required cryptography.SecretKey key,
    required String canonical,
    required int chunkIndex,
  }) async {
    final aad = utf8.encode('$canonical\n$chunkIndex\n${plaintext.length}');
    final secretBox = await cryptography.AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: key,
      nonce: _chunkNonce(chunkIndex),
      aad: aad,
    );
    final framePayloadLength = secretBox.cipherText.length + secretBox.mac.bytes.length;
    final frame = Uint8List(_frameHeaderBytes + framePayloadLength);
    ByteData.sublistView(frame).setUint32(0, framePayloadLength, Endian.big);
    frame.setRange(_frameHeaderBytes, _frameHeaderBytes + secretBox.cipherText.length, secretBox.cipherText);
    frame.setRange(_frameHeaderBytes + secretBox.cipherText.length, frame.length, secretBox.mac.bytes);
    return frame;
  }

  Stream<List<int>> _readFixedChunks(File file, int chunkSize) async* {
    var carry = Uint8List(0);
    await for (final incoming in file.openRead()) {
      final combined = Uint8List(carry.length + incoming.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + incoming.length, incoming);
      var offset = 0;
      while (combined.length - offset >= chunkSize) {
        yield Uint8List.fromList(combined.sublist(offset, offset + chunkSize));
        offset += chunkSize;
      }
      carry = Uint8List.fromList(combined.sublist(offset));
    }
    if (carry.isNotEmpty) yield carry;
  }

  Stream<List<int>> _encryptedUploadFrames({
    required File file,
    required int totalBytes,
    required cryptography.SecretKey key,
    required String canonical,
    required void Function(int sentBytes, int totalBytes) onProgress,
  }) async* {
    var chunkIndex = 0;
    var sentBytes = 0;
    if (totalBytes == 0) {
      yield await _encryptFrame(plaintext: const <int>[], key: key, canonical: canonical, chunkIndex: chunkIndex);
      onProgress(0, 0);
      return;
    }
    await for (final plaintext in _readFixedChunks(file, _encryptionChunkSize)) {
      final frame = await _encryptFrame(
        plaintext: plaintext,
        key: key,
        canonical: canonical,
        chunkIndex: chunkIndex,
      );
      yield frame;
      sentBytes += plaintext.length;
      chunkIndex += 1;
      onProgress(sentBytes, totalBytes);
    }
  }

  Future<LanviTransferReceipt> uploadFile({
    required LanviPairing pairing,
    required PlatformFile selectedFile,
    required void Function(int sentBytes, int totalBytes) onProgress,
  }) async {
    final localPath = selectedFile.path;
    if (localPath == null || localPath.isEmpty) {
      throw FileSystemException(
        'Lanvi could not access a local file path for ${selectedFile.name}. Re-select the file from device storage.',
      );
    }

    final file = File(localPath);
    if (!await file.exists()) {
      throw FileSystemException('The selected file is no longer available.', localPath);
    }

    final totalBytes = await file.length();
    final String expectedSha256;
    if (totalBytes == 0) {
      expectedSha256 = digest.sha256.convert(const <int>[]).toString().toLowerCase();
    } else {
      final sourceDigest = await digest.sha256.bind(file.openRead()).first;
      expectedSha256 = sourceDigest.toString().toLowerCase();
    }

    final requestUri = pairing.baseUri.replace(path: '/api/upload');
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final requestNonce = _createNonce();
    final canonical = _uploadCanonical(
      timestamp: timestamp,
      nonce: requestNonce,
      filename: selectedFile.name,
      size: totalBytes,
      sha256: expectedSha256,
    );
    final signature = digest.Hmac(digest.sha256, utf8.encode(pairing.token))
        .convert(utf8.encode(canonical))
        .toString();
    final encryptionKey = await _deriveUploadKey(token: pairing.token, requestNonce: requestNonce);
    // Let HTTP use chunked transfer framing for this streamed encrypted body.
    // The receiver validates the number/length of AES-GCM frames and the final
    // plaintext byte count + SHA-256, avoiding mismatches between transport
    // Content-Length and the X-Lanvi-Size plaintext header.
    final client = http.Client();
    final request = http.StreamedRequest('POST', requestUri)
      ..contentLength = null
      ..headers.addAll(<String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/octet-stream',
        'X-Lanvi-Timestamp': timestamp,
        'X-Lanvi-Nonce': requestNonce,
        'X-Lanvi-Filename-B64': base64Url.encode(utf8.encode(selectedFile.name)).replaceAll('=', ''),
        'X-Lanvi-Size': totalBytes.toString(),
        'X-Lanvi-SHA256': expectedSha256,
        'X-Lanvi-Encryption': _encryptionVersion,
        'X-Lanvi-Chunk-Size': _encryptionChunkSize.toString(),
        'X-Lanvi-Signature': signature,
      });

    final uploadStopwatch = Stopwatch()..start();
    try {
      // Listen for the response while encrypted file chunks are streamed to the PC.
      final responseFuture = client.send(request);
      Object? uploadError;
      final uploadFuture = request.sink.addStream(_encryptedUploadFrames(
        file: file,
        totalBytes: totalBytes,
        key: encryptionKey,
        canonical: canonical,
        onProgress: onProgress,
      )).then<void>((_) => request.sink.close()).catchError(
        (Object error, StackTrace stackTrace) {
          uploadError = error;
        },
      );

      final response = await responseFuture;
      final responseText = await response.stream.bytesToString();
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(responseText);
        body = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        body = <String, dynamic>{};
      }

      if (response.statusCode == 401) {
        throw const HttpException(
          'The pairing code has expired or is invalid. Open the Chrome receiver, generate a fresh QR code, and scan it again.',
        );
      }
      if (response.statusCode != 201) {
        final message = body['error']?.toString() ?? 'The PC rejected the encrypted upload (HTTP ${response.statusCode}).';
        throw HttpException(message);
      }
      await uploadFuture;
      uploadStopwatch.stop();
      if (uploadError != null) {
        throw HttpException('The encrypted upload stream was interrupted: $uploadError');
      }

      final receivedHash = body['sha256']?.toString().toLowerCase() ?? '';
      final receivedSize = (body['size'] as num?)?.toInt() ?? -1;
      if (receivedHash != expectedSha256 || receivedSize != totalBytes) {
        throw LanviIntegrityException(
          filename: selectedFile.name,
          expectedHash: expectedSha256,
          receivedHash: receivedHash,
          size: totalBytes,
        );
      }

      final elapsedSeconds = (uploadStopwatch.elapsedMicroseconds / 1000000).clamp(0.001, 86400.0);
      final measuredRate = totalBytes / (1024 * 1024) / elapsedSeconds;
      _lastUploadMegabytesPerSecond = measuredRate;
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setDouble(_lastUploadRateKey, measuredRate);
      } catch (_) {
        // A local preference failure must not turn a verified transfer into a failure.
      }

      return LanviTransferReceipt(
        id: body['id']?.toString() ?? '',
        filename: body['filename']?.toString() ?? selectedFile.name,
        size: receivedSize,
        sha256: receivedHash,
        status: body['status']?.toString() ?? 'staged',
      );
    } finally {
      client.close();
    }
  }

}
