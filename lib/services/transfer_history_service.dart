// Purpose: Keeps a small, local-only history of phone-to-PC transfers and their integrity results.
// How to use: Call TransferHistoryService.instance from the sender and history page.
// Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.5.0 — supports pull-to-refresh on the local transfer history page.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanviTransferHistoryEntry {
  const LanviTransferHistoryEntry({
    required this.id,
    required this.filename,
    required this.size,
    required this.status,
    required this.timestamp,
    required this.pcHost,
    this.sha256,
    this.message,
  });

  final String id;
  final String filename;
  final int size;
  final String status;
  final DateTime timestamp;
  final String pcHost;
  final String? sha256;
  final String? message;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'filename': filename,
        'size': size,
        'status': status,
        'timestamp': timestamp.toIso8601String(),
        'pcHost': pcHost,
        'sha256': sha256,
        'message': message,
      };

  factory LanviTransferHistoryEntry.fromJson(Map<String, dynamic> json) =>
      LanviTransferHistoryEntry(
        id: json['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
        filename: json['filename']?.toString() ?? 'Unknown file',
        size: (json['size'] as num?)?.toInt() ?? 0,
        status: json['status']?.toString() ?? 'failed',
        timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
        pcHost: json['pcHost']?.toString() ?? '',
        sha256: json['sha256']?.toString(),
        message: json['message']?.toString(),
      );
}

class TransferHistoryService extends ChangeNotifier {
  TransferHistoryService._();

  static final TransferHistoryService instance = TransferHistoryService._();
  static const String _storageKey = 'lanvi.transfer.history';
  static const int _maxEntries = 100;

  final List<LanviTransferHistoryEntry> _entries = <LanviTransferHistoryEntry>[];
  bool _isLoaded = false;
  Future<void>? _loadFuture;

  List<LanviTransferHistoryEntry> get entries => List.unmodifiable(_entries);
  bool get isLoaded => _isLoaded;

  Future<void> load() {
    if (_isLoaded) return Future<void>.value();
    return _loadFuture ??= _loadInternal();
  }

  /// Reloads the persisted local history when the user pulls down to refresh.
  Future<void> reload() async {
    _isLoaded = false;
    _loadFuture = null;
    _entries.clear();
    await load();
  }

  Future<void> _loadInternal() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _entries
            ..clear()
            ..addAll(decoded.whereType<Map>().map((item) =>
                LanviTransferHistoryEntry.fromJson(Map<String, dynamic>.from(item))));
        }
      }
    } catch (_) {
      _entries.clear();
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> add(LanviTransferHistoryEntry entry) async {
    await load();
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    await load();
    _entries.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _storageKey,
        jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (_) {
      // A history persistence issue must not interrupt the transfer itself.
    }
  }
}
