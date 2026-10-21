// Purpose: Captures Android SEND/SEND_MULTIPLE file shares and queues paths for Lanvi's native transfer screen.
// How to use: Initialize once before runApp; HomePage consumes pending file paths and opens the transfer screen.
// Project: Lanvi | Release: 1.2.1 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.2.1 — receives shared files from Gallery, Files, and other Android apps.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

class LanviShareIntentService extends ChangeNotifier {
  LanviShareIntentService._();

  static final LanviShareIntentService instance = LanviShareIntentService._();

  StreamSubscription<List<SharedMediaFile>>? _subscription;
  final List<String> _pendingPaths = <String>[];
  bool _initialized = false;
  String? _lastError;

  List<String> get pendingPaths => List<String>.unmodifiable(_pendingPaths);
  String? get lastError => _lastError;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isAndroid) return;

    _subscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      _queueSharedFiles,
      onError: (Object error, StackTrace stackTrace) {
        _lastError = 'Could not read a shared file: $error';
        notifyListeners();
      },
    );

    try {
      final initialFiles = await ReceiveSharingIntent.instance.getInitialMedia();
      _queueSharedFiles(initialFiles);
      if (initialFiles.isNotEmpty) ReceiveSharingIntent.instance.reset();
    } catch (error) {
      _lastError = 'Could not read files shared while Lanvi was closed: $error';
      notifyListeners();
    }
  }

  void _queueSharedFiles(List<SharedMediaFile> sharedFiles) {
    var changed = false;
    for (final sharedFile in sharedFiles) {
      final path = sharedFile.path.trim();
      if (path.isEmpty || _pendingPaths.contains(path)) continue;
      _pendingPaths.add(path);
      changed = true;
    }
    if (sharedFiles.isNotEmpty) ReceiveSharingIntent.instance.reset();
    if (changed) notifyListeners();
  }

  List<String> consumePendingPaths() {
    final consumed = List<String>.from(_pendingPaths);
    _pendingPaths.clear();
    _lastError = null;
    notifyListeners();
    return consumed;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
