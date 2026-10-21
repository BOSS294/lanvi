// Purpose: Persist locally remembered Lanvi devices and user-defined display aliases.
// Integration: Use LanviDeviceRegistryService.instance from device management and pairing flows.
// Project: Lanvi | Release: 0.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Ensures empty registry results are mutable before add/remove operations.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class LanviKnownDevice {
  const LanviKnownDevice({
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.address,
    required this.port,
    required this.firstPairedAt,
    required this.lastSeenAt,
    this.pairingExpiresAt,
    this.alias,
  });

  final String deviceId;
  final String name;
  final String deviceType;
  final String address;
  final int port;
  final DateTime firstPairedAt;
  final DateTime? lastSeenAt;
  final DateTime? pairingExpiresAt;
  final String? alias;

  String get displayName => (alias?.trim().isNotEmpty ?? false) ? alias!.trim() : name;
  bool get pairingMayBeExpired => pairingExpiresAt != null && !pairingExpiresAt!.isAfter(DateTime.now());

  factory LanviKnownDevice.fromJson(Map<String, dynamic> json) {
    return LanviKnownDevice(
      deviceId: (json['deviceId'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? 'Lanvi device').trim(),
      deviceType: (json['deviceType'] as String? ?? 'desktop').trim(),
      address: (json['address'] as String? ?? '').trim(),
      port: (json['port'] as num?)?.toInt() ?? 8787,
      firstPairedAt: DateTime.tryParse(json['firstPairedAt'] as String? ?? '') ?? DateTime.now(),
      lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? ''),
      pairingExpiresAt: DateTime.tryParse(json['pairingExpiresAt'] as String? ?? ''),
      alias: (json['alias'] as String?)?.trim(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'name': name,
        'deviceType': deviceType,
        'address': address,
        'port': port,
        'firstPairedAt': firstPairedAt.toIso8601String(),
        'lastSeenAt': lastSeenAt?.toIso8601String(),
        'pairingExpiresAt': pairingExpiresAt?.toIso8601String(),
        'alias': alias,
      };

  LanviKnownDevice copyWith({
    String? name,
    String? address,
    int? port,
    DateTime? lastSeenAt,
    DateTime? pairingExpiresAt,
    String? alias,
    bool clearAlias = false,
  }) => LanviKnownDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        deviceType: deviceType,
        address: address ?? this.address,
        port: port ?? this.port,
        firstPairedAt: firstPairedAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        pairingExpiresAt: pairingExpiresAt ?? this.pairingExpiresAt,
        alias: clearAlias ? null : (alias ?? this.alias),
      );
}

class LanviDeviceRegistryService {
  LanviDeviceRegistryService._();

  static final LanviDeviceRegistryService instance = LanviDeviceRegistryService._();
  static const String _knownDevicesKey = 'lanvi.devices.known.v1';
  static const String _aliasesKey = 'lanvi.devices.aliases.v1';

  Future<List<LanviKnownDevice>> loadKnownDevices() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_knownDevicesKey);
      if (raw == null || raw.isEmpty) return <LanviKnownDevice>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <LanviKnownDevice>[];
      final devices = decoded
          .whereType<Map>()
          .map((item) => LanviKnownDevice.fromJson(Map<String, dynamic>.from(item)))
          .where((device) => device.deviceId.isNotEmpty)
          .toList();
      final aliases = await _loadAliases(preferences);
      return devices.map((device) => device.copyWith(alias: aliases[device.deviceId])).toList()
        ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    } catch (_) {
      return <LanviKnownDevice>[];
    }
  }

  Future<Map<String, String>> _loadAliases(SharedPreferences preferences) async {
    try {
      final raw = preferences.getString(_aliasesKey);
      if (raw == null || raw.isEmpty) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> rememberPc({
    required String deviceId,
    required String name,
    required String address,
    required int port,
    DateTime? pairingExpiresAt,
  }) async {
    if (deviceId.trim().isEmpty || address.trim().isEmpty || port < 1 || port > 65535) return;
    final preferences = await SharedPreferences.getInstance();
    final existing = List<LanviKnownDevice>.of(await loadKnownDevices(), growable: true);
    final now = DateTime.now();
    final index = existing.indexWhere((device) => device.deviceId == deviceId);
    final aliases = await _loadAliases(preferences);
    final known = LanviKnownDevice(
      deviceId: deviceId,
      name: name.trim().isEmpty ? 'Lanvi PC' : name.trim(),
      deviceType: 'desktop',
      address: address,
      port: port,
      firstPairedAt: index >= 0 ? existing[index].firstPairedAt : now,
      lastSeenAt: now,
      pairingExpiresAt: pairingExpiresAt,
      alias: aliases[deviceId],
    );
    if (index >= 0) {
      existing[index] = known;
    } else {
      existing.add(known);
    }
    await preferences.setString(_knownDevicesKey, jsonEncode(existing.map((device) => device.toJson()).toList()));
  }

  Future<void> renameDevice(String deviceId, String displayName) async {
    final trimmed = displayName.trim();
    if (deviceId.trim().isEmpty || trimmed.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final aliases = await _loadAliases(preferences);
    aliases[deviceId] = trimmed.substring(0, trimmed.length > 64 ? 64 : trimmed.length);
    await preferences.setString(_aliasesKey, jsonEncode(aliases));
  }

  Future<void> clearDeviceAlias(String deviceId) async {
    final preferences = await SharedPreferences.getInstance();
    final aliases = await _loadAliases(preferences);
    aliases.remove(deviceId);
    await preferences.setString(_aliasesKey, jsonEncode(aliases));
  }

  Future<void> forgetDevice(String deviceId) async {
    final preferences = await SharedPreferences.getInstance();
    final known = List<LanviKnownDevice>.of(await loadKnownDevices(), growable: true);
    known.removeWhere((device) => device.deviceId == deviceId);
    await preferences.setString(_knownDevicesKey, jsonEncode(known.map((device) => device.toJson()).toList()));
    await clearDeviceAlias(deviceId);
  }
}
