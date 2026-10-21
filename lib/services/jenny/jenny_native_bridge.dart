// Purpose: Typed MethodChannel bridge for Jenny's Android-only communications and security features.
// Integration: Keep at lib/services/jenny/jenny_native_bridge.dart.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Explicit runtime permissions, encrypted provider secrets, roles and user-confirmed intents.

import 'package:flutter/services.dart';

class JennyNativeBridge {
  JennyNativeBridge._();
  static final JennyNativeBridge instance = JennyNativeBridge._();
  static const MethodChannel _channel = MethodChannel('lanvi/jenny_native');

  Future<void> saveSecret(String provider, String secret) async =>
      _channel.invokeMethod<void>('saveSecret', {'provider': provider, 'secret': secret});

  Future<String?> readSecret(String provider) =>
      _channel.invokeMethod<String>('readSecret', {'provider': provider});

  Future<bool> hasSecret(String provider) async =>
      await _channel.invokeMethod<bool>('hasSecret', {'provider': provider}) ?? false;

  Future<void> deleteSecret(String provider) =>
      _channel.invokeMethod<void>('deleteSecret', {'provider': provider});

  Future<void> saveRuntimePolicy(Map<String, Object?> policy) =>
      _channel.invokeMethod<void>('saveRuntimePolicy', {'policy': policy});

  Future<Map<String, Object?>> readRuntimePolicy() async =>
      (await _channel.invokeMapMethod<String, Object?>('readRuntimePolicy')) ?? <String, Object?>{};

  Future<bool> requestRuntimePermissions(List<String> permissions) async =>
      await _channel.invokeMethod<bool>('requestRuntimePermissions', {'permissions': permissions}) ?? false;

  Future<bool> requestCallScreeningRole() async =>
      await _channel.invokeMethod<bool>('requestCallScreeningRole') ?? false;
  Future<bool> hasCallScreeningRole() async =>
      await _channel.invokeMethod<bool>('hasCallScreeningRole') ?? false;

  Future<bool> requestOverlayPermission() async =>
      await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;
  Future<bool> hasOverlayPermission() async =>
      await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
  Future<bool> hasFullScreenIntentPermission() async =>
      await _channel.invokeMethod<bool>('hasFullScreenIntentPermission') ?? false;
  Future<bool> requestFullScreenIntentPermission() async =>
      await _channel.invokeMethod<bool>('requestFullScreenIntentPermission') ?? false;
  Future<void> setOverlayEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setOverlayEnabled', {'enabled': enabled});

  Future<void> openNotificationPolicySettings() =>
      _channel.invokeMethod<void>('openNotificationPolicySettings');
  Future<void> openEmergencyDemo() => _channel.invokeMethod<void>('openEmergencyDemo');

  Future<List<Map<String, Object?>>> getContacts() async =>
      _toMaps(await _channel.invokeListMethod<Object?>('getContacts'));
  Future<List<Map<String, Object?>>> getRecentSms() async =>
      _toMaps(await _channel.invokeListMethod<Object?>('getRecentSms'));
  Future<List<Map<String, Object?>>> getRecentCalls() async =>
      _toMaps(await _channel.invokeListMethod<Object?>('getRecentCalls'));

  Future<void> openDialer(String phoneNumber) =>
      _channel.invokeMethod<void>('openDialer', {'number': phoneNumber});
  Future<void> openSmsComposer(String phoneNumber, String body) =>
      _channel.invokeMethod<void>('openSmsComposer', {'number': phoneNumber, 'body': body});
  Future<void> openWhatsApp(String phoneNumber, String body) =>
      _channel.invokeMethod<void>('openWhatsApp', {'number': phoneNumber, 'body': body});
  Future<void> sendSmsAfterConfirmation(String phoneNumber, String body) =>
      _channel.invokeMethod<void>('sendSmsAfterConfirmation', {'number': phoneNumber, 'body': body});

  List<Map<String, Object?>> _toMaps(List<Object?>? values) {
    if (values == null || values.isEmpty) return <Map<String, Object?>>[];
    return values.whereType<Map<Object?, Object?>>().map((value) => value.map(
      (key, item) => MapEntry(key.toString(), item),
    )).toList(growable: false);
  }
}
