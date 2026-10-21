/*
 * Purpose: Let the user explicitly enable or disable phone-to-PC media streaming and inspect indexed audio/video files.
 * Integration: Add MediaLibraryPage to HomePage navigation; routes are served by LanviMediaLibraryService.
 * Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
 * Changelog: Adds opt-in audio/video permission, library scan, folder-oriented listing, and local-only sharing controls.
 */
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/lanvi_media_library_service.dart';

class MediaLibraryPage extends StatefulWidget {
  const MediaLibraryPage({super.key});

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  final LanviMediaLibraryService _media = LanviMediaLibraryService.instance;
  String _filter = 'all';
  String _query = '';
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _media.loadPreferences();
      if (_media.sharingEnabled) await _media.refreshLibrary();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not initialize media library: $error')),
      );
    }
  }

  Future<void> _enable() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final enabled = await _media.enableSharing();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(enabled
            ? 'Media library enabled. The paired PC can browse supported audio and video files while Lanvi stays open.'
            : (_media.errorMessage ?? 'Media access was not enabled.')),
      ));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not enable media sharing: $error')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _disable() async {
    await _media.disableSharing();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Media sharing is paused. Existing playback sessions will stop refreshing.')));
  }

  Future<void> _refresh() async {
    try {
      if (!_media.sharingEnabled) {
        await _media.loadPreferences();
      }
      if (_media.sharingEnabled) await _media.refreshLibrary();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Media library refresh failed: $error')));
    }
  }

  String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024;
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[index]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnimatedBuilder(
      animation: _media,
      builder: (context, _) {
        final allItems = _media.items;
        final visible = allItems.where((item) {
          final matchesKind = _filter == 'all' || item.kind == _filter;
          final q = _query.trim().toLowerCase();
          final matchesQuery = q.isEmpty || item.name.toLowerCase().contains(q) || item.relativePath.toLowerCase().contains(q);
          return matchesKind && matchesQuery;
        }).toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Media Library'),
            actions: [
              IconButton(
                tooltip: 'Refresh media library',
                onPressed: _media.scanning ? null : _refresh,
                icon: AnimatedRotation(
                  turns: _media.scanning ? 1 : 0,
                  duration: const Duration(milliseconds: 420),
                  child: Icon(PhosphorIcons.arrowsClockwise(PhosphorIconsStyle.light)),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator.adaptive(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(AppSpacing.pageHorizontal, AppSpacing.md, AppSpacing.pageHorizontal, AppSpacing.xl),
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withOpacity(0.55),
                      borderRadius: AppRadius.large,
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: AppRadius.medium),
                          alignment: Alignment.center,
                          child: Icon(PhosphorIcons.waveform(PhosphorIconsStyle.light), color: colors.onPrimaryContainer, size: 26),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Stream your media to PC', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text('Browse music and movies from Lanvi for Chrome. Your files remain on the phone and are served on demand.', style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant, height: 1.45)),
                        ])),
                      ]),
                      const SizedBox(height: AppSpacing.md),
                      Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
                        _CountPill(icon: PhosphorIcons.musicNotes(PhosphorIconsStyle.light), text: '${_media.musicCount} music'),
                        _CountPill(icon: PhosphorIcons.filmSlate(PhosphorIconsStyle.light), text: '${_media.videoCount} videos'),
                      ]),
                      const SizedBox(height: AppSpacing.md),
                      if (!_media.sharingEnabled)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _working ? null : _enable,
                            icon: _working ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(PhosphorIcons.folderOpen(PhosphorIconsStyle.light)),
                            label: Text(_working ? 'Requesting access…' : 'Enable media sharing'),
                          ),
                        )
                      else
                        Row(children: [
                          Expanded(child: Row(children: [
                            const Icon(Icons.circle, color: Color(0xFF16A34A), size: 11),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(child: Text('Media sharing enabled', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                          ])),
                          TextButton(onPressed: _disable, child: const Text('Pause sharing')),
                        ]),
                    ]),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(color: colors.surface, borderRadius: AppRadius.large, border: Border.all(color: colors.outlineVariant)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(PhosphorIcons.shieldCheck(PhosphorIconsStyle.light), color: colors.primary, size: 23),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(
                        'Local-only access. Only a PC paired with the current Lanvi QR token can request the encrypted media chunks. Keep Lanvi open while streaming; media is served from shared Music, Movies, Download, DCIM, Podcasts, Audiobooks, Recordings and Android/media folders.',
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
                      )),
                    ]),
                  ),
                  if (_media.errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(color: colors.errorContainer.withOpacity(0.55), borderRadius: AppRadius.medium),
                      child: Row(children: [Icon(PhosphorIcons.warningCircle(PhosphorIconsStyle.light), color: colors.error), const SizedBox(width: AppSpacing.sm), Expanded(child: Text(_media.errorMessage!, style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer)))]),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Text('On this phone', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: 'Search tracks, movies or folders',
                      prefixIcon: Icon(PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light)),
                      border: OutlineInputBorder(borderRadius: AppRadius.medium),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SegmentedButton<String>(
                    segments: const <ButtonSegment<String>>[
                      ButtonSegment(value: 'all', label: Text('All media')),
                      ButtonSegment(value: 'music', label: Text('Music')),
                      ButtonSegment(value: 'video', label: Text('Videos')),
                    ],
                    selected: <String>{_filter},
                    onSelectionChanged: (value) {
                      if (value.isNotEmpty) {
                        setState(() => _filter = value.first);
                      }
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (!_media.sharingEnabled)
                    const _EmptyMediaNotice(title: 'Enable media access to scan', subtitle: 'Lanvi asks for Android audio/video permission only after you tap Enable media sharing.')
                  else if (_media.scanning)
                    const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator()))
                  else if (visible.isEmpty)
                    _EmptyMediaNotice(title: 'No media matches', subtitle: 'Try another filter or pull down to refresh the phone library.')
                  else
                    ...visible.map((item) => Padding(
                      key: ValueKey<String>(item.id),
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                        shape: RoundedRectangleBorder(borderRadius: AppRadius.medium),
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: AppRadius.small),
                          alignment: Alignment.center,
                          child: Icon(item.kind == 'music' ? PhosphorIcons.musicNote(PhosphorIconsStyle.light) : PhosphorIcons.filmSlate(PhosphorIconsStyle.light), color: colors.primary),
                        ),
                        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text('${item.relativePath} · ${_formatBytes(item.size)}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: Icon(PhosphorIcons.checkCircle(PhosphorIconsStyle.light), color: colors.primary),
                      ),
                    )),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Playback happens on the PC', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Lanvi for Chrome opens music in Lanvi Music and movies in the Lanvi Cinema player. Chrome codec support varies by format; VLC-style controls cannot add a codec that Chrome itself cannot decode.', style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.45)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: colors.outlineVariant)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 17, color: colors.primary), const SizedBox(width: AppSpacing.xs), Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700))]),
    );
  }
}

class _EmptyMediaNotice extends StatelessWidget {
  const _EmptyMediaNotice({required this.title, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35), borderRadius: AppRadius.large, border: Border.all(color: theme.colorScheme.outlineVariant)),
      child: Column(children: [Icon(PhosphorIcons.folderOpen(PhosphorIconsStyle.light), size: 28, color: theme.colorScheme.onSurfaceVariant), const SizedBox(height: AppSpacing.sm), Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: AppSpacing.xs), Text(subtitle, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4))]),
    );
  }
}
