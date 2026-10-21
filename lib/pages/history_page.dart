// Purpose: Displays locally persisted transfer attempts and SHA-256 outcomes from the Flutter LAN sender.
// How to use: Render HistoryPage in the HomePage tab stack.
// Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.5.0 — adds smooth scrolling and pull-to-refresh for local transfer records.

import 'package:flutter/material.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/transfer_history_service.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final TransferHistoryService _history = TransferHistoryService.instance;

  @override
  void initState() {
    super.initState();
    _history.addListener(_onHistoryChanged);
    _history.load();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _history.removeListener(_onHistoryChanged);
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear sharing history?'),
        content: const Text('This removes Lanvi’s local history records. Files already downloaded to the PC are not deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear history')),
        ],
      ),
    );
    if (confirmed == true) await _history.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final entries = _history.entries;

    return RefreshIndicator(
      onRefresh: _history.reload,
      color: scheme.primary,
      backgroundColor: scheme.surface,
      displacement: 56,
      edgeOffset: 4,
      strokeWidth: 2.4,
      triggerMode: RefreshIndicatorTriggerMode.onEdge,
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sharing history', style: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Local records of files sent to your PC.', style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (entries.isNotEmpty)
              IconButton(
                tooltip: 'Clear history',
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (!_history.isLoaded)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (entries.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: AppRadius.large,
            ),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(color: scheme.primary.withOpacity(0.10), borderRadius: AppRadius.large),
                  alignment: Alignment.center,
                  child: Icon(Icons.history, size: 32, color: scheme.primary),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Nothing shared yet', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'When you send files from Lanvi, the outcome and integrity verification will appear here.',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                ),
              ],
            ),
          )
        else
          ...entries.map((entry) {
            final success = entry.status == 'completed';
            return Container(
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: AppRadius.large,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.all(AppSpacing.md),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (success ? const Color(0xFF0F3D26) : scheme.error).withOpacity(0.10),
                    borderRadius: AppRadius.medium,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    success ? Icons.check_circle_outline : Icons.error_outline,
                    color: success ? const Color(0xFF0F3D26) : scheme.error,
                  ),
                ),
                title: Text(entry.filename, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_formatBytes(entry.size)} · ${_formatDate(entry.timestamp)}', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(success ? 'Received by PC · SHA-256 verified' : 'Failed · ${entry.message ?? 'See transfer details'}', style: textTheme.bodySmall?.copyWith(color: success ? scheme.primary : scheme.error)),
                      if (entry.sha256 != null) ...[
                        const SizedBox(height: 4),
                        Text('SHA-256: ${entry.sha256}', maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                      if (entry.pcHost.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('PC: ${entry.pcHost}', style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
                isThreeLine: true,
              ),
            );
          }),
        ],
      ),
    );
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

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day/$month/${local.year} $hour:$minute';
  }
}
