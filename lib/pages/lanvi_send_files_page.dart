// Purpose: Lets the user choose one or more local files and send them to the paired PC over the LAN bridge.
// How to use: Push LanviSendFilesPage with the saved LanviPairing; each transfer is streamed and hash-verified.
// Project: Lanvi | Release: 1.2.2 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.2.2 — fixes selected-file count labels and adds chunked encrypted HTTP upload compatibility.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/lanvi_connection_service.dart';
import '../services/transfer_history_service.dart';
import 'lanvi_pairing_page.dart';

class LanviSendFilesPage extends StatefulWidget {
  const LanviSendFilesPage({
    super.key,
    required this.pairing,
    this.sharedFilePaths = const <String>[],
    this.autoSendInitialFiles = false,
  });

  final LanviPairing pairing;
  final List<String> sharedFilePaths;
  final bool autoSendInitialFiles;

  @override
  State<LanviSendFilesPage> createState() => _LanviSendFilesPageState();
}

class _LanviSendFilesPageState extends State<LanviSendFilesPage> {
  List<PlatformFile> _selectedFiles = <PlatformFile>[];
  bool _isSending = false;
  int _currentFileIndex = 0;
  int _completedFiles = 0;
  int _currentFileSent = 0;
  int _currentFileTotal = 0;
  String? _statusMessage;
  bool _hasError = false;

  String _readyToSendLabel(int count) {
    if (count <= 0) return '';
    if (count == 1) return '1 file ready to send.';
    return '${count.toString()} files ready to send.';
  }

  String _sharedFilesLabel(int count) {
    if (count <= 0) return 'No files received from Android Share.';
    if (count == 1) return 'Received 1 file from Android Share.';
    return 'Received ${count.toString()} files from Android Share.';
  }

  @override
  void initState() {
    super.initState();
    if (widget.sharedFilePaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSharedFiles());
    }
  }

  Future<void> _loadSharedFiles() async {
    final files = <PlatformFile>[];
    final errors = <String>[];
    for (final path in widget.sharedFilePaths) {
      try {
        final file = File(path);
        if (!await file.exists()) {
          errors.add('Shared file is no longer available: $path');
          continue;
        }
        final length = await file.length();
        final pieces = path.split(Platform.pathSeparator);
        final name = pieces.isEmpty || pieces.last.isEmpty ? 'shared-file' : pieces.last;
        files.add(PlatformFile(name: name, size: length, path: path));
      } catch (error) {
        errors.add('Could not open shared file: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedFiles = files;
      _statusMessage = files.isEmpty
          ? (errors.isEmpty ? _sharedFilesLabel(0) : errors.join('\n'))
          : _sharedFilesLabel(files.length);
      _hasError = files.isEmpty;
    });
    if (files.isNotEmpty && widget.autoSendInitialFiles) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isSending) _sendFiles();
      });
    }
  }

  int get _totalBytes => _selectedFiles.fold<int>(0, (sum, file) => sum + file.size);
  int get _bytesCompletedBeforeCurrent => _selectedFiles.take(_completedFiles).fold<int>(0, (sum, file) => sum + file.size);
  double get _overallProgress {
    final total = _totalBytes;
    if (total <= 0) return 0;
    return ((_bytesCompletedBeforeCurrent + _currentFileSent).clamp(0, total)) / total;
  }

  Future<void> _pickFiles() async {
    if (_isSending) return;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      if (!mounted || result == null) return;
      setState(() {
        _selectedFiles = result.files;
        _statusMessage = result.files.isEmpty ? null : _readyToSendLabel(result.files.length);
        _hasError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Could not open the file picker: $error';
        _hasError = true;
      });
    }
  }

  Future<void> _sendFiles() async {
    if (_isSending || _selectedFiles.isEmpty) return;

    final isOnline = await LanviConnectionService.instance.checkHealth(widget.pairing);
    if (!mounted) return;
    if (!isOnline) {
      setState(() {
        _statusMessage = 'The PC is not reachable. Keep the bridge running and check that both devices share the same reachable Wi-Fi network.';
        _hasError = true;
      });
      return;
    }

    setState(() {
      _isSending = true;
      _completedFiles = 0;
      _currentFileIndex = 0;
      _currentFileSent = 0;
      _currentFileTotal = 0;
      _statusMessage = 'Preparing transfer…';
      _hasError = false;
    });

    for (var index = 0; index < _selectedFiles.length; index++) {
      final selectedFile = _selectedFiles[index];
      if (!mounted) return;
      setState(() {
        _currentFileIndex = index;
        _currentFileSent = 0;
        _currentFileTotal = selectedFile.size;
        _statusMessage = 'Sending ${selectedFile.name}';
      });

      try {
        final receipt = await LanviConnectionService.instance.uploadFile(
          pairing: widget.pairing,
          selectedFile: selectedFile,
          onProgress: (sentBytes, totalBytes) {
            if (!mounted) return;
            setState(() {
              _currentFileSent = sentBytes;
              _currentFileTotal = totalBytes;
            });
          },
        );

        await TransferHistoryService.instance.add(
          LanviTransferHistoryEntry(
            id: receipt.id.isEmpty ? DateTime.now().microsecondsSinceEpoch.toString() : receipt.id,
            filename: receipt.filename,
            size: receipt.size,
            status: 'completed',
            timestamp: DateTime.now(),
            pcHost: widget.pairing.host,
            sha256: receipt.sha256,
            message: 'Received by PC and source SHA-256 matched the bridge SHA-256.',
          ),
        );
        _completedFiles++;
        if (mounted) {
          setState(() {
            _statusMessage = 'Verified ${receipt.filename}';
          });
        }
      } catch (error) {
        String? localHash;
        if (error is LanviIntegrityException) {
          localHash = error.expectedHash;
        }
        await TransferHistoryService.instance.add(
          LanviTransferHistoryEntry(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            filename: selectedFile.name,
            size: selectedFile.size,
            status: 'failed',
            timestamp: DateTime.now(),
            pcHost: widget.pairing.host,
            sha256: localHash,
            message: error.toString(),
          ),
        );
        if (!mounted) return;
        setState(() {
          _statusMessage = error.toString().replaceFirst('Exception: ', '');
          _hasError = true;
        });
        break;
      }
    }

    if (!mounted) return;
    final allCompleted = _completedFiles == _selectedFiles.length;
    setState(() {
      _isSending = false;
      if (allCompleted) {
        _currentFileSent = _currentFileTotal;
        _statusMessage = 'All $_completedFiles file(s) received and integrity-verified by the PC bridge.';
        _selectedFiles = <PlatformFile>[];
        _hasError = false;
      }
    });
  }

  Future<void> _repairPairing() async {
    if (_isSending) return;
    final paired = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const LanviPairingPage()),
    );
    if (paired == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final overall = _overallProgress;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Send files'),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: _isSending ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          TextButton.icon(
            onPressed: _isSending ? null : _repairPairing,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Re-pair'),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: AppRadius.large,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(PhosphorIcons.monitor(PhosphorIconsStyle.light), size: 28, color: scheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sending to this PC', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('${widget.pairing.host}:${widget.pairing.port}', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Icon(Icons.wifi, color: scheme.primary),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Choose your files', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Select images, videos, documents or any other file exposed by Android’s file picker. Lanvi sends original bytes and verifies the PC’s SHA-256 result.',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: _isSending ? null : _pickFiles,
              icon: const Icon(Icons.add_rounded),
              label: Text(_selectedFiles.isEmpty ? 'Select files' : 'Add / replace selection'),
            ),
            if (_selectedFiles.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: Text('${_selectedFiles.length.toString()} selected', style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  Text(_formatBytes(_totalBytes), style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ..._selectedFiles.map((file) => Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: AppRadius.medium,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(_iconForFile(file.name), color: scheme.primary, size: 24),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(_formatBytes(file.size), style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  )),
            ],
            if (_isSending || _statusMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: _hasError ? scheme.errorContainer : scheme.surface,
                  borderRadius: AppRadius.large,
                  border: Border.all(color: _hasError ? scheme.error : scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_isSending)
                          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary))
                        else
                          Icon(_hasError ? Icons.error_outline : Icons.check_circle_outline, color: _hasError ? scheme.error : scheme.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _statusMessage ?? 'Ready',
                            style: textTheme.bodyMedium?.copyWith(
                              color: _hasError ? scheme.onErrorContainer : scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_isSending) ...[
                      const SizedBox(height: AppSpacing.md),
                      LinearProgressIndicator(value: overall.clamp(0.0, 1.0)),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'File ${_currentFileIndex + 1} of ${_selectedFiles.length} · ${_formatBytes(_currentFileSent)} / ${_formatBytes(_currentFileTotal)}',
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _isSending || _selectedFiles.isEmpty ? null : _sendFiles,
              icon: _isSending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.arrow_upward_rounded),
              label: Text(_isSending ? 'Sending…' : 'Send to PC'),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Local-network prototype: transfers use HTTP and a temporary pairing token. Use only your trusted private Wi-Fi. The connection and integrity checks do not yet provide transport encryption.',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForFile(String name) {
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'bmp'].contains(extension)) return Icons.image_outlined;
    if (['mp4', 'mov', 'mkv', 'webm', 'avi', '3gp'].contains(extension)) return Icons.movie_outlined;
    if (['mp3', 'wav', 'aac', 'flac', 'm4a', 'ogg'].contains(extension)) return Icons.audio_file_outlined;
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var size = bytes / 1024;
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index++;
    }
    return '${size.toStringAsFixed(1)} ${units[index]}';
  }
}
