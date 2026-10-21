// Purpose: Load SMS, call history and contacts only after explicit Android permission grants.
// Integration: JennyControlCenterPage; Android may restrict these capabilities to eligible default handlers.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Runtime permission requests are routed through the matching native Android permission names.

import 'jenny_native_bridge.dart';

class JennyActivityService {
  JennyActivityService._();
  static final JennyActivityService instance = JennyActivityService._();
  final JennyNativeBridge _native = JennyNativeBridge.instance;

  Future<bool> requestContactsAccess() => _native.requestRuntimePermissions(
    const <String>['android.permission.READ_CONTACTS'],
  );

  Future<bool> requestSmsAccess() => _native.requestRuntimePermissions(
    const <String>[
      'android.permission.READ_SMS',
      'android.permission.RECEIVE_SMS',
      'android.permission.SEND_SMS',
    ],
  );

  Future<bool> requestCallLogAccess() => _native.requestRuntimePermissions(
    const <String>[
      'android.permission.READ_CALL_LOG',
      'android.permission.READ_PHONE_STATE',
      'android.permission.SEND_SMS',
    ],
  );

  Future<List<Map<String, Object?>>> contacts() => _native.getContacts();
  Future<List<Map<String, Object?>>> smsHistory() => _native.getRecentSms();
  Future<List<Map<String, Object?>>> callHistory() => _native.getRecentCalls();
}
