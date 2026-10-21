import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lanvi_connection_service.dart';

@immutable
class LanviMediaItem {
  const LanviMediaItem({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.kind,
    required this.mimeType,
    required this.size,
    required this.modifiedAt,
    required this.path,
  });

  final String id;
  final String name;
  final String relativePath;
  final String kind;
  final String mimeType;
  final int size;
  final DateTime modifiedAt;
  final String path;

  Map<String, Object?> toPublicJson() => <String, Object?>{
        'id': id,
        'name': name,
        'relativePath': relativePath,
        'folder': relativePath.contains('/') ? relativePath.substring(0, relativePath.lastIndexOf('/')) : '',
        'kind': kind,
        'mimeType': mimeType,
        'size': size,
        'modifiedAt': modifiedAt.toIso8601String(),
      };
}

class LanviMediaLibraryService extends ChangeNotifier {
  LanviMediaLibraryService._();
  static final LanviMediaLibraryService instance = LanviMediaLibraryService._();

  static const String _sharingKey = 'lanvi.media.sharing_enabled';
  static const int chunkSize = 1024 * 1024;
  static const String _protocol = 'lanvi-media-v1';
  static const String _kdfInfoPrefix = 'lanvi-media-aes-256-gcm-v1';
  static const int _authClockSkewMs = 120000;
  static const int _maxItems = 3000;

  final Map<String, LanviMediaItem> _items = <String, LanviMediaItem>{};
  final Map<String, int> _usedNonces = <String, int>{};
  bool _sharingEnabled = false;
  bool _scanning = false;
  DateTime? _lastScanAt;
  String? _errorMessage;
  Future<void>? _scanOperation;

  bool get sharingEnabled => _sharingEnabled;
  bool get scanning => _scanning;
  String? get errorMessage => _errorMessage;
  List<LanviMediaItem> get items => List<LanviMediaItem>.unmodifiable(_items.values.toList()
    ..sort((a, b) => a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase())));
  int get musicCount => _items.values.where((item) => item.kind == 'music').length;
  int get videoCount => _items.values.where((item) => item.kind == 'video').length;

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _sharingEnabled = prefs.getBool(_sharingKey) ?? false;
    notifyListeners();
  }

  Future<bool> enableSharing() async {
    if (!Platform.isAndroid) {
      _errorMessage = 'Phone media sharing is currently supported on Android.';
      notifyListeners();
      return false;
    }

    Map<Permission, PermissionStatus> statuses;
    try {
      statuses = await <Permission>[Permission.audio, Permission.videos].request();
    } catch (_) {
      statuses = <Permission, PermissionStatus>{};
    }
    var granted = statuses.values.any((status) => status.isGranted || status.isLimited);
    if (!granted) {
      // Android 12 and earlier use READ_EXTERNAL_STORAGE. On newer releases
      // these legacy requests can be denied, so the modern media grants above
      // remain the preferred route.
      final legacy = await Permission.storage.request();
      granted = legacy.isGranted || legacy.isLimited;
    }
    if (!granted) {
      _errorMessage = 'Allow audio or video access in Android settings to share your media library.';
      notifyListeners();
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sharingKey, true);
    _sharingEnabled = true;
    await refreshLibrary();
    return true;
  }

  Future<void> disableSharing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sharingKey, false);
    _sharingEnabled = false;
    notifyListeners();
  }

  Future<void> refreshLibrary() async {
    if (_scanOperation != null) return _scanOperation!;
    final operation = _scan();
    _scanOperation = operation;
    try {
      await operation;
    } finally {
      _scanOperation = null;
    }
  }

  Future<void> _scan() async {
    _scanning = true;
    _errorMessage = null;
    notifyListeners();
    final found = <String, LanviMediaItem>{};
    if (!Platform.isAndroid) {
      _errorMessage = 'Media library indexing is currently supported on Android phones.';
      _scanning = false;
      notifyListeners();
      return;
    }
    const roots = <String>[
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/Videos',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Podcasts',
      '/storage/emulated/0/Audiobooks',
      '/storage/emulated/0/Recordings',
      '/storage/emulated/0/Android/media',
    ];
    final visited = <String>{};
    for (final rootPath in roots) {
      if (found.length >= _maxItems) break;
      final root = Directory(rootPath);
      try {
        if (!await root.exists()) continue;
        await _walk(root, rootPath, 0, visited, found);
      } catch (_) {
        // Some manufacturers restrict individual folders; keep scanning others.
      }
    }
    _items
      ..clear()
      ..addAll(found);
    _lastScanAt = DateTime.now();
    _scanning = false;
    if (_items.isEmpty) {
      _errorMessage = 'No supported media files found in shared Music, Movies, Download, DCIM or related folders.';
    }
    notifyListeners();
  }

  Future<void> _walk(
    Directory directory,
    String rootPath,
    int depth,
    Set<String> visited,
    Map<String, LanviMediaItem> found,
  ) async {
    if (depth > 5 || found.length >= _maxItems) return;
    final normalized = directory.absolute.path;
    if (!visited.add(normalized)) return;
    await for (final entity in directory.list(followLinks: false, recursive: false)) {
      if (found.length >= _maxItems) break;
      final name = entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;
      if (name.isEmpty || name.startsWith('.')) continue;
      try {
        if (entity is Directory) {
          // Avoid app-private and other protected Android paths.
          if (name == 'data' || name == 'obb') continue;
          await _walk(entity, rootPath, depth + 1, visited, found);
        } else if (entity is File) {
          final metadata = _classify(name);
          if (metadata == null) continue;
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file || stat.size <= 0) continue;
          final fullPath = entity.absolute.path;
          if (found.values.any((item) => item.path == fullPath)) continue;
          final relative = fullPath.startsWith(rootPath)
              ? '${_rootLabel(rootPath)}/${fullPath.substring(rootPath.length).replaceFirst(RegExp(r'^[/\\]+'), '').replaceAll('\\', '/')}'
              : name;
          final modifiedMs = stat.modified.millisecondsSinceEpoch;
          final id = digest.sha256.convert(utf8.encode('$fullPath|${stat.size}|$modifiedMs')).toString().substring(0, 32);
          found[id] = LanviMediaItem(
            id: id,
            name: name,
            relativePath: relative,
            kind: metadata.$1,
            mimeType: metadata.$2,
            size: stat.size,
            modifiedAt: stat.modified,
            path: fullPath,
          );
        }
      } catch (_) {
        // One inaccessible file must not interrupt the entire library scan.
      }
    }
  }

  String _rootLabel(String root) => root.split('/').where((part) => part.isNotEmpty).last;

  (String, String)? _classify(String filename) {
    final ext = filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
    const audio = <String, String>{
      'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac',
      'flac': 'audio/flac', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
      'opus': 'audio/ogg', 'wma': 'audio/x-ms-wma', 'aiff': 'audio/aiff',
      'alac': 'audio/mp4', 'mid': 'audio/midi', 'midi': 'audio/midi',
    };
    const video = <String, String>{
      'mp4': 'video/mp4', 'm4v': 'video/x-m4v', 'mov': 'video/quicktime',
      'webm': 'video/webm', 'mkv': 'video/x-matroska', 'avi': 'video/x-msvideo',
      'wmv': 'video/x-ms-wmv', 'flv': 'video/x-flv', 'mpeg': 'video/mpeg',
      'mpg': 'video/mpeg', '3gp': 'video/3gpp', 'ts': 'video/mp2t',
    };
    if (audio.containsKey(ext)) return ('music', audio[ext]!);
    if (video.containsKey(ext)) return ('video', video[ext]!);
    return null;
  }

  Future<void> _ensureScanned() async {
    if (!_sharingEnabled) throw const _MediaHttpError(HttpStatus.forbidden, 'Media sharing is disabled. Open Lanvi on the phone and enable Media Library sharing.');
    final stale = _lastScanAt == null || DateTime.now().difference(_lastScanAt!) > const Duration(minutes: 2);
    if (stale || _items.isEmpty) await refreshLibrary();
    if (_items.isEmpty) throw const _MediaHttpError(HttpStatus.notFound, 'No supported audio or video files are available in the shared media folders.');
  }

  Future<void> handleRequest(
    HttpRequest request, {
    required String ownDeviceId,
    required String ownDeviceName,
  }) async {
    final path = request.uri.path;
    if (request.method != 'GET' || !<String>{'/api/media/catalog', '/api/media/chunk'}.contains(path)) {
      await _writeJson(request, HttpStatus.notFound, <String, Object?>{'error': 'Unknown media endpoint.'});
      return;
    }

    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !_isLocalAddress(remote.address)) {
        throw const _MediaHttpError(HttpStatus.forbidden, 'Media access is restricted to the local network.');
      }
      await _ensureScanned();
      final pairing = await LanviConnectionService.instance.loadPairing();
      if (pairing == null || pairing.deviceId == null || pairing.deviceId!.isEmpty) {
        throw const _MediaHttpError(HttpStatus.unauthorized, 'Pair this phone with the PC by scanning the current QR code first.');
      }
      final requesterId = (request.headers.value('x-lanvi-requester-device-id') ?? '').trim();
      if (requesterId != pairing.deviceId) {
        throw const _MediaHttpError(HttpStatus.forbidden, 'This PC is not the currently paired Lanvi receiver.');
      }
      final timestamp = request.headers.value('x-lanvi-timestamp') ?? '';
      final nonce = (request.headers.value('x-lanvi-nonce') ?? '').toLowerCase();
      final signature = (request.headers.value('x-lanvi-signature') ?? '').toLowerCase();
      final time = int.tryParse(timestamp);
      if (time == null || (DateTime.now().millisecondsSinceEpoch - time).abs() > _authClockSkewMs ||
          !RegExp(r'^[a-f0-9]{48}$').hasMatch(nonce) || !RegExp(r'^[a-f0-9]{64}$').hasMatch(signature)) {
        throw const _MediaHttpError(HttpStatus.unauthorized, 'Media request authentication is expired or malformed.');
      }
      _pruneNonces();
      if (_usedNonces.containsKey(nonce)) throw const _MediaHttpError(HttpStatus.conflict, 'Media request replay detected. Retry playback.');
      final pathAndQuery = request.uri.path + (request.uri.hasQuery ? '?${request.uri.query}' : '');
      final canonical = <String>['GET', pathAndQuery, timestamp, nonce, requesterId].join('\n');
      final expectedSignature = digest.Hmac(digest.sha256, utf8.encode(pairing.token)).convert(utf8.encode(canonical)).toString();
      if (!_constantTimeHexEquals(expectedSignature, signature)) throw const _MediaHttpError(HttpStatus.unauthorized, 'Media request authentication failed. Rescan the current PC QR code.');
      _usedNonces[nonce] = DateTime.now().millisecondsSinceEpoch + _authClockSkewMs;

      if (path == '/api/media/catalog') {
        final items = _items.values.toList()..sort((a, b) => a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()));
        final body = <String, Object?>{
          'protocol': _protocol,
          'deviceId': ownDeviceId,
          'deviceName': ownDeviceName,
          'chunkSize': chunkSize,
          'items': items.map((item) => item.toPublicJson()).toList(growable: false),
        };
        await _writeSignedJson(request, pairing.token, HttpStatus.ok, body, timestamp, nonce);
        return;
      }

      final mediaId = request.uri.queryParameters['mediaId'] ?? '';
      final sessionId = request.uri.queryParameters['sessionId'] ?? '';
      final chunkIndex = int.tryParse(request.uri.queryParameters['index'] ?? '');
      final item = _items[mediaId];
      if (item == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(mediaId)) throw const _MediaHttpError(HttpStatus.notFound, 'Media file is no longer available. Refresh the media library.');
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sessionId) || chunkIndex == null || chunkIndex < 0 || chunkIndex * chunkSize >= item.size) {
        throw const _MediaHttpError(HttpStatus.badRequest, 'Invalid media chunk request.');
      }
      final offset = chunkIndex * chunkSize;
      final length = math.min(chunkSize, item.size - offset).toInt();
      final file = File(item.path);
      final currentStat = await file.stat();
      if (currentStat.type != FileSystemEntityType.file ||
          currentStat.size != item.size ||
          currentStat.modified.millisecondsSinceEpoch != item.modifiedAt.millisecondsSinceEpoch) {
        throw const _MediaHttpError(HttpStatus.conflict, 'Media file changed after the library scan. Refresh the library and reopen it.');
      }
      final raf = await file.open(mode: FileMode.read);
      Uint8List plain;
      try {
        await raf.setPosition(offset);
        plain = Uint8List.fromList(await raf.read(length));
      } finally {
        await raf.close();
      }
      if (plain.length != length) throw const _MediaHttpError(HttpStatus.conflict, 'Media file changed during streaming. Refresh the library and retry.');

      final salt = Uint8List.fromList(<int>[..._decodeHex(sessionId), ..._decodeHex(nonce)]);
      final hkdf = cryptography.Hkdf(hmac: cryptography.Hmac.sha256(), outputLength: 32);
      final key = await hkdf.deriveKey(
        secretKey: cryptography.SecretKey(utf8.encode(pairing.token)),
        nonce: salt,
        info: utf8.encode('$_kdfInfoPrefix:$mediaId:$chunkIndex'),
      );
      final chunkNonce = Uint8List(12);
      ByteData.sublistView(chunkNonce).setUint64(4, chunkIndex, Endian.big);
      final aad = utf8.encode('lanvi-media-chunk-v1\n${pairing.deviceId}\n$mediaId\n${item.size}\n$sessionId\n$chunkIndex\n${plain.length}\n$nonce');
      final encrypted = await cryptography.AesGcm.with256bits().encrypt(
        plain,
        secretKey: key,
        nonce: chunkNonce,
        aad: aad,
      );
      final cipherTextLength = encrypted.cipherText.length;
      final macBytes = encrypted.mac.bytes;
      final payload = Uint8List(cipherTextLength + macBytes.length)
        ..setRange(0, cipherTextLength, encrypted.cipherText)
        ..setRange(cipherTextLength, cipherTextLength + macBytes.length, macBytes);
      await _writeSignedBytes(request, pairing.token, HttpStatus.ok, payload, timestamp, nonce, ContentType.binary);
    } on _MediaHttpError catch (error) {
      await _writeJson(request, error.status, <String, Object?>{'error': error.message});
    } catch (error) {
      _errorMessage = 'Media streaming request failed: $error';
      notifyListeners();
      await _writeJson(request, HttpStatus.internalServerError, <String, Object?>{'error': 'Lanvi could not read this media file.'});
    }
  }

  bool _isLocalAddress(String value) {
    final address = value.startsWith('::ffff:') ? value.substring(7) : value;
    if (address == '127.0.0.1' || address == '::1') return true;
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null || part < 0 || part > 255)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
  }

  bool _constantTimeHexEquals(String left, String right) {
    if (left.length != right.length || !RegExp(r'^[a-f0-9]+$').hasMatch(left) || !RegExp(r'^[a-f0-9]+$').hasMatch(right)) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return difference == 0;
  }

  Uint8List _decodeHex(String value) => Uint8List.fromList(List<int>.generate(value.length ~/ 2,
      (index) => int.parse(value.substring(index * 2, index * 2 + 2), radix: 16)));

  void _pruneNonces() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _usedNonces.removeWhere((_, expiry) => expiry <= now);
    if (_usedNonces.length > 20000) {
      final keys = _usedNonces.keys.take(_usedNonces.length - 15000).toList();
      for (final key in keys) { _usedNonces.remove(key); }
    }
  }

  Future<void> _writeJson(HttpRequest request, int status, Map<String, Object?> object) async {
    final bytes = utf8.encode(jsonEncode(object));
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  String _responseSignature(String token, String timestamp, String nonce, int status, List<int> bytes) {
    final hash = digest.sha256.convert(bytes).toString();
    final canonical = <String>['LANVI-MEDIA-RESPONSE', timestamp, nonce, status.toString(), hash].join('\n');
    return digest.Hmac(digest.sha256, utf8.encode(token)).convert(utf8.encode(canonical)).toString();
  }

  Future<void> _writeSignedJson(HttpRequest request, String token, int status, Map<String, Object?> object, String timestamp, String nonce) async {
    final bytes = utf8.encode(jsonEncode(object));
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.set('X-Lanvi-Response-Signature', _responseSignature(token, timestamp, nonce, status, bytes))
      ..headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _writeSignedBytes(HttpRequest request, String token, int status, Uint8List bytes, String timestamp, String nonce, ContentType contentType) async {
    request.response
      ..statusCode = status
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.set('X-Lanvi-Response-Signature', _responseSignature(token, timestamp, nonce, status, bytes))
      ..headers.set('X-Lanvi-Plaintext-Length', (bytes.length - 16).toString())
      ..headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }
}

class _MediaHttpError implements Exception {
  const _MediaHttpError(this.status, this.message);
  final int status;
  final String message;
}
