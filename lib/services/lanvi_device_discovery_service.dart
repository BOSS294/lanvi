// Purpose: Advertise this Lanvi client and discover compatible devices over the local network.
// Integration: Start once from main.dart; observe with AnimatedBuilder and use refreshDiscovery() for rescans.
// Project: Lanvi | Release: 0.6.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds mDNS discovery, multi-address deduplication, local device identity and a public info-only endpoint.
// Security: Discovery results are untrusted hints. They never grant transfer authorization.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_service.dart';
import 'lanvi_media_library_service.dart';

@immutable
class LanviDiscoveredDevice {
  const LanviDiscoveredDevice({
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.addresses,
    required this.port,
    required this.protocol,
    required this.capabilities,
    required this.isOnline,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.offlineSince,
  });

  final String deviceId;
  final String name;
  final String deviceType;
  final List<String> addresses;
  final int port;
  final String protocol;
  final String capabilities;
  final bool isOnline;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? offlineSince;

  String get primaryAddress => addresses.isEmpty ? '' : addresses.first;
  bool get isDesktop => deviceType == 'desktop';
  bool get isMobile => deviceType == 'mobile' || deviceType == 'tablet';

  LanviDiscoveredDevice copyWith({
    List<String>? addresses,
    bool? isOnline,
    DateTime? lastSeenAt,
    DateTime? offlineSince,
    String? name,
  }) => LanviDiscoveredDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        deviceType: deviceType,
        addresses: addresses ?? this.addresses,
        port: port,
        protocol: protocol,
        capabilities: capabilities,
        isOnline: isOnline ?? this.isOnline,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        offlineSince: offlineSince,
      );
}

class LanviDeviceDiscoveryService extends ChangeNotifier {
  LanviDeviceDiscoveryService._();

  static final LanviDeviceDiscoveryService instance = LanviDeviceDiscoveryService._();
  static const String serviceType = '_lanvi._tcp';
  static const String protocolName = 'lanvi-discovery-v1';
  static const String _deviceIdKey = 'lanvi.devices.local_id.v1';
  static const String _deviceNameKey = 'lanvi.devices.local_name.v1';
  static const Duration _staleAfter = Duration(seconds: 90);

  final Map<String, LanviDiscoveredDevice> _devices = <String, LanviDiscoveredDevice>{};
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<dynamic>? _discoverySubscription;
  HttpServer? _infoServer;
  Timer? _cleanupTimer;
  String? _ownDeviceId;
  String? _ownDeviceName;
  bool _starting = false;
  bool _started = false;
  bool _scanning = false;
  bool _advertising = false;
  String? _error;

  List<LanviDiscoveredDevice> get devices {
    final values = _devices.values.toList()
      ..sort((a, b) {
        final online = (b.isOnline ? 1 : 0).compareTo(a.isOnline ? 1 : 0);
        return online != 0 ? online : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return List<LanviDiscoveredDevice>.unmodifiable(values);
  }

  String? get ownDeviceId => _ownDeviceId;
  String get ownDeviceName => _ownDeviceName ?? 'Lanvi device';
  bool get isScanning => _scanning;
  bool get isAdvertising => _advertising;
  bool get isStarted => _started;
  String? get errorMessage => _error;

  Future<void> start() async {
    if (_started || _starting) return;
    _starting = true;
    _error = null;
    notifyListeners();
    try {
      await _loadLocalIdentity();
      _infoServer = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
      _infoServer!.listen(_handleInfoRequest, onError: (Object error) {
        _error = 'Local device info listener failed: $error';
        notifyListeners();
      });
      await _startBroadcast();
      await _startDiscovery();
      _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _removeStaleDevices());
      _started = true;
    } catch (error) {
      _error = _friendlyError(error);
      await _stopInternal();
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _loadLocalIdentity() async {
    final preferences = await SharedPreferences.getInstance();
    _ownDeviceId = preferences.getString(_deviceIdKey);
    if (_ownDeviceId == null || _ownDeviceId!.trim().length < 24) {
      _ownDeviceId = _randomHex(16);
      await preferences.setString(_deviceIdKey, _ownDeviceId!);
    }

    _ownDeviceName = preferences.getString(_deviceNameKey);
    if (_ownDeviceName == null || _ownDeviceName!.trim().isEmpty) {
      String username = 'Lanvi phone';
      try {
        username = (await ProfileService.getUsername()).trim();
      } catch (_) {
        // Default remains useful if profile storage is not ready yet.
      }
      _ownDeviceName = username.isEmpty ? (Platform.isAndroid ? 'Lanvi phone' : 'Lanvi device') : '$username phone';
      await preferences.setString(_deviceNameKey, _ownDeviceName!);
    }
    final normalizedName = _ownDeviceName!.trim();
    _ownDeviceName = normalizedName.substring(0, normalizedName.length > 64 ? 64 : normalizedName.length);
  }

  String _randomHex(int byteCount) {
    final random = math.Random.secure();
    return List<int>.generate(byteCount, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String get _deviceType {
    if (Platform.isAndroid || Platform.isIOS) return 'mobile';
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return 'desktop';
    return 'unknown';
  }

  String get _deviceCapabilities => Platform.isAndroid || Platform.isIOS
      ? 'send-to-pc,device-management,media-library,media-streaming'
      : 'lanvi-discovery,device-management';

  Future<void> _startBroadcast() async {
    final id = _ownDeviceId;
    final name = _ownDeviceName;
    final server = _infoServer;
    if (id == null || name == null || server == null) return;
    final service = BonsoirService(
      name: 'Lanvi-${id.substring(0, 8)}',
      type: serviceType,
      port: server.port,
      attributes: <String, String>{
        'protocol': protocolName,
        'deviceId': id,
        'deviceType': _deviceType,
        'deviceName': name,
        'capabilities': _deviceCapabilities,
        'appVersion': '0.6.0',
        'infoPath': '/api/device-info',
      },
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
    _advertising = true;
  }

  Future<void> _startDiscovery() async {
    final discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    final eventStream = discovery.eventStream;
    if (eventStream == null) {
      throw StateError('Local network discovery did not expose its event stream.');
    }
    _discoverySubscription = eventStream.listen(_handleDiscoveryEvent, onError: (Object error) {
      _error = _friendlyError(error);
      _scanning = false;
      notifyListeners();
    });
    _discovery = discovery;
    await discovery.start();
    _scanning = true;
  }

  void _handleDiscoveryEvent(dynamic event) {
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      // Concrete Bonsoir 7.1.4 service events expose a non-null service.
      final discovery = _discovery;
      if (discovery != null) {
        event.service.resolve(discovery.serviceResolver);
      }
      return;
    }

    if (event is BonsoirDiscoveryServiceResolvedEvent) {
      _upsertService(event.service);
      return;
    }

    if (event is BonsoirDiscoveryServiceUpdatedEvent) {
      _upsertService(event.service);
      return;
    }

    if (event is BonsoirDiscoveryServiceLostEvent) {
      _markServiceLost(event.service);
    }
  }

  void _upsertService(BonsoirService service) {
    final attributes = service.attributes;
    if (attributes['protocol'] != protocolName) return;
    final id = (attributes['deviceId'] ?? '').trim();
    if (id.isEmpty || id == _ownDeviceId) return;
    final type = (attributes['deviceType'] ?? 'unknown').toLowerCase();
    if (!const <String>{'desktop', 'mobile', 'tablet'}.contains(type)) return;

    final addressValues = <String>{};
    for (final raw in service.hostAddresses) {
      final parsed = InternetAddress.tryParse(raw.toString());
      if (parsed == null || parsed.type != InternetAddressType.IPv4 || !_isLocalIPv4(parsed.address)) continue;
      addressValues.add(parsed.address);
    }
    final existing = _devices[id];
    final now = DateTime.now();
    final addresses = <String>{...(existing?.addresses ?? const <String>[]), ...addressValues}.toList();
    _devices[id] = LanviDiscoveredDevice(
      deviceId: id,
      name: (attributes['deviceName'] ?? service.name).trim().isEmpty ? service.name : (attributes['deviceName'] ?? service.name).trim(),
      deviceType: type,
      addresses: addresses,
      port: service.port,
      protocol: protocolName,
      capabilities: attributes['capabilities'] ?? '',
      isOnline: true,
      firstSeenAt: existing?.firstSeenAt ?? now,
      lastSeenAt: now,
      offlineSince: null,
    );
    notifyListeners();
  }

  void _markServiceLost(BonsoirService service) {
    final id = (service.attributes['deviceId'] ?? '').trim();
    final existing = _devices[id];
    if (existing == null) return;
    _devices[id] = existing.copyWith(isOnline: false, offlineSince: DateTime.now());
    notifyListeners();
  }

  void _removeStaleDevices() {
    final now = DateTime.now();
    final stale = _devices.entries.where((entry) => !entry.value.isOnline && now.difference(entry.value.offlineSince ?? entry.value.lastSeenAt) > _staleAfter).map((entry) => entry.key).toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _devices.remove(id);
    }
    notifyListeners();
  }

  bool _isLocalIPv4(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null || part < 0 || part > 255)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 169 && second == 254);
  }

  Future<void> _handleInfoRequest(HttpRequest request) async {
    // Media catalog and encrypted chunk endpoints share the advertised local
    // discovery port, keeping the phone reachable through its existing mDNS record.
    if (request.uri.path.startsWith('/api/media/')) {
      await LanviMediaLibraryService.instance.handleRequest(
        request,
        ownDeviceId: _ownDeviceId ?? 'unknown',
        ownDeviceName: _ownDeviceName ?? 'Lanvi phone',
      );
      return;
    }

    request.response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    if (request.method != 'GET' || request.uri.path != '/api/device-info') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final remote = request.connectionInfo?.remoteAddress;
    final remoteAddress = remote?.address.toLowerCase() ?? '';
    final isLocalIpv6 = remote != null && remote.type == InternetAddressType.IPv6 &&
        (remote.isLoopback || remoteAddress.startsWith('fe80:') || remoteAddress.startsWith('fc') || remoteAddress.startsWith('fd'));
    if (remote == null || !(remote.isLoopback || _isLocalIPv4(remote.address) || isLocalIpv6)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.write(jsonEncode(<String, Object?>{
      'protocol': protocolName,
      'deviceId': _ownDeviceId,
      'deviceName': _ownDeviceName,
      'deviceType': _deviceType,
      'capabilities': _deviceCapabilities.split(','),
      'transferReady': false,
      'note': 'Discovery metadata only. Pairing and transfer authorization are separate.',
    }));
    await request.response.close();
  }

  Future<void> refreshDiscovery() async {
    if (!_started) {
      await start();
      return;
    }
    _error = null;
    try {
      await _discovery?.stop();
      _scanning = false;
      notifyListeners();
      await _discovery?.start();
      _scanning = true;
    } catch (error) {
      _error = _friendlyError(error);
    }
    notifyListeners();
  }

  Future<void> renameThisDevice(String value) async {
    final name = value.trim();
    if (name.isEmpty || name.length > 64) throw ArgumentError('Device name must contain 1–64 characters.');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_deviceNameKey, name);
    _ownDeviceName = name;
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    _advertising = false;
    await _startBroadcast();
    notifyListeners();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('permission') || text.contains('Permission')) {
      return 'Local network permission is unavailable. Allow local network access in Android settings and try again.';
    }
    return 'Lanvi could not start local network discovery. Check Wi-Fi, app permissions and whether local discovery is blocked by the network.';
  }

  Future<void> _stopInternal() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    try { await _discoverySubscription?.cancel(); } catch (_) {}
    _discoverySubscription = null;
    try { await _discovery?.stop(); } catch (_) {}
    _discovery = null;
    try { await _broadcast?.stop(); } catch (_) {}
    _broadcast = null;
    try { await _infoServer?.close(force: true); } catch (_) {}
    _infoServer = null;
    _scanning = false;
    _advertising = false;
    _started = false;
  }

  Future<void> stop() async {
    await _stopInternal();
    notifyListeners();
  }
}
