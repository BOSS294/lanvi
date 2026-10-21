// Purpose: Store non-secret Jenny preferences locally and mirror deterministic rules to Android.
// Integration: JennyControlCenterPage uses the singleton instance.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds explicit Busy/Sleep, contact-only AI, spam filtering, and emergency settings.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jenny_native_bridge.dart';

class JennySettingsService extends ChangeNotifier {
  JennySettingsService._();
  static final JennySettingsService instance = JennySettingsService._();

  static const String _storageKey = 'lanvi.jenny.settings';

  final Map<String, Object?> _defaults = <String, Object?>{
    'assistantName': 'Jenny',
    'mode': 'normal',
    'groqModel': 'openai/gpt-oss-20b',
    'approvedContext': 'Mayank Chawdhari is a software developer and the creator of Lanvi. Only share information explicitly written in this approved context. Do not disclose private details, credentials, addresses, private messages, or information not provided here. Identify yourself as Jenny, Mayank\'s AI personal assistant.',
    'autoDeclineBusySleep': false,
    'autoReplyBusySleep': true,
    'autoReplyMissedCalls': true,
    'aiSmsRepliesEnabled': false,
    'onlySavedContacts': true,
    'blockKnownSpam': true,
    'blockUnknownCallers': false,
    'emergencyAlertsEnabled': true,
    'emergencyMaxVolume': true,
    'overlayEnabled': false,
    'proactiveCheckIns': false,
    'localOnlyMode': false,
    'voiceProvider': 'system',
    'voiceLanguage': 'hi-IN',
    'sarvamModel': 'bulbul:v4-flash',
    'sarvamSpeaker': 'ishita_enhi_customer',
    'busyMessage': 'Hi, I\'m Jenny, Mayank\'s AI personal assistant. Mayank is currently busy and cannot take your call right now. If this is important, please leave a message here. I will flag it for him as soon as he is available. Thank you.',
    'sleepMessage': 'Hi, I\'m Jenny, Mayank\'s AI personal assistant. Mayank is currently resting and may not see your message until later. If this is important, please leave a message here and I will flag it for him when he wakes. Thank you, and good night.',
    'missedCallMessage': 'Hi, I\'m Jenny, Mayank\'s AI personal assistant. Sorry, Mayank was unable to attend your call. Was it something important? Please type your message here and I will let him know as soon as he checks his phone. Thank you.',
    'blockedNumbers': <String>[],
    'priorityNumbers': <String>[],
  };

  Map<String, Object?> _values = <String, Object?>{};
  bool _loaded = false;
  bool get loaded => _loaded;
  Map<String, Object?> get values => Map<String, Object?>.unmodifiable(_values);

  T get<T>(String key) {
    final value = _values[key] ?? _defaults[key];
    if (value is T) return value;
    return _defaults[key] as T;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    Map<String, Object?> stored = <String, Object?>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          stored = decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {
        // Ignore malformed local preferences and restore safe defaults.
      }
    }
    _values = <String, Object?>{..._defaults, ...stored};
    // Migrate early test values to currently documented Bulbul v4 Flash speaker IDs.
    final savedSpeaker = _values['sarvamSpeaker']?.toString() ?? '';
    if (savedSpeaker == 'ishita_enhi_companion') _values['sarvamSpeaker'] = 'ishita_enhi_customer';
    if (savedSpeaker == 'shalini_enhi_companion') _values['sarvamSpeaker'] = 'simran_enhi_customer';
    _loaded = true;
    await _persistAndMirror(notify: false);
    notifyListeners();
  }

  Future<void> setValue(String key, Object? value) async {
    if (!_loaded) await load();
    _values[key] = value;
    await _persistAndMirror();
  }

  Future<void> setMany(Map<String, Object?> changes) async {
    if (!_loaded) await load();
    _values.addAll(changes);
    await _persistAndMirror();
  }

  Future<void> _persistAndMirror({bool notify = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_values));
    // Keep Android's short, local-only automation policy in sync for background receivers.
    await JennyNativeBridge.instance.saveRuntimePolicy(_values);
    if (notify) notifyListeners();
  }

  String get mode => get<String>('mode');
  bool get isBusyOrSleeping => mode == 'busy' || mode == 'sleep';

  String deterministicAutoReply() => mode == 'sleep'
      ? get<String>('sleepMessage')
      : get<String>('busyMessage');
}
