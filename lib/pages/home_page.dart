// Purpose: Integrates Lanvi's Phase 01 dashboard with native LAN pairing, real file sending, and local transfer history.
// How to use: Replace the existing lib/pages/home_page.dart with this file's contents, keeping the HomePage class name.
// Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.5.0 — fixes PathMetrics iterator handling, uses a cropped symbol asset, keeps unknown throughput gray, and maps measured upload rate to four animated signal arcs.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../core/style/glass_panel.dart';
import '../core/theme/theme_catalog.dart';
import '../services/avatar_service.dart';
import '../services/lanvi_connection_service.dart';
import '../services/lanvi_share_intent_service.dart';
import '../services/profile_service.dart';
import 'history_page.dart';
import 'devices_page.dart';
import 'lanvi_pairing_page.dart';
import 'lanvi_send_files_page.dart';
import 'media_library_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  String _username = 'Lanvi user';
  String _avatarSeed = 'Lanvi';
  LanviPairing? _pairing;
  bool _pcOnline = false;
  bool _checkingPc = true;
  bool _handlingIncomingShares = false;
  int? _connectionLatencyMs;
  double? _lastUploadMegabytesPerSecond;
  final LanviShareIntentService _shareIntentService = LanviShareIntentService.instance;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _refreshConnection();
    _shareIntentService.addListener(_onPendingShareChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingSharedFiles());
  }

  @override
  void dispose() {
    _shareIntentService.removeListener(_onPendingShareChanged);
    super.dispose();
  }

  void _onPendingShareChanged() {
    if (_shareIntentService.pendingPaths.isNotEmpty) {
      unawaited(_handlePendingSharedFiles());
    }
  }

  Future<void> _handlePendingSharedFiles() async {
    if (!mounted || _handlingIncomingShares) return;
    final pendingPaths = _shareIntentService.pendingPaths;
    if (pendingPaths.isEmpty) return;

    _handlingIncomingShares = true;
    var allowQueueRerun = false;
    try {
      var pairing = await LanviConnectionService.instance.loadPairing();
      final pcIsReachable = pairing != null && await LanviConnectionService.instance.checkHealth(pairing);
      if (!pcIsReachable) {
        final paired = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(builder: (_) => const LanviPairingPage()),
        );
        if (paired != true || !mounted) return;
        pairing = await LanviConnectionService.instance.loadPairing();
      }
      if (!mounted || pairing == null) return;

      final pathsToSend = _shareIntentService.consumePendingPaths();
      if (pathsToSend.isEmpty) return;
      allowQueueRerun = true;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => LanviSendFilesPage(
            pairing: pairing!,
            sharedFilePaths: pathsToSend,
            autoSendInitialFiles: true,
          ),
        ),
      );
      await _refreshConnection();
    } finally {
      _handlingIncomingShares = false;
      if (allowQueueRerun && mounted && _shareIntentService.pendingPaths.isNotEmpty) {
        unawaited(_handlePendingSharedFiles());
      }
    }
  }

  Future<void> _loadProfile() async {
    final username = await ProfileService.getUsername();
    final seed = await ProfileService.getAvatarSeed();
    if (!mounted) return;
    setState(() {
      if (username.trim().isNotEmpty) _username = username;
      _avatarSeed = seed;
    });
  }

  Future<void> _refreshConnection() async {
    if (!mounted) return;
    setState(() => _checkingPc = true);

    final connectionService = LanviConnectionService.instance;
    final pairing = await connectionService.loadPairing();
    final stopwatch = Stopwatch()..start();
    final isOnline = pairing != null && await connectionService.checkHealth(pairing);
    stopwatch.stop();
    final lastUploadRate = await connectionService.loadLastUploadMegabytesPerSecond();

    if (!mounted) return;
    setState(() {
      _pairing = pairing;
      _pcOnline = isOnline;
      _connectionLatencyMs = isOnline ? stopwatch.elapsedMilliseconds : null;
      _lastUploadMegabytesPerSecond = lastUploadRate;
      _checkingPc = false;
    });
  }

  Future<void> _connectPc() async {
    final paired = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const LanviPairingPage()),
    );
    if (paired == true) {
      await _refreshConnection();
      if (_shareIntentService.pendingPaths.isNotEmpty) {
        unawaited(_handlePendingSharedFiles());
      }
    }
  }

  Future<void> _sendFiles() async {
    var pairing = _pairing;
    if (pairing == null) {
      await _connectPc();
      pairing = _pairing;
      if (pairing == null) return;
    }

    final online = await LanviConnectionService.instance.checkHealth(pairing);
    if (!mounted) return;
    setState(() => _pcOnline = online);
    if (!online) {
      final shouldReconnect = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('PC is not reachable'),
          content: const Text('Start the Lanvi PC bridge and keep your phone and PC on the same reachable local network. You can scan a fresh QR code to reconnect.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Scan QR again')),
          ],
        ),
      );
      if (shouldReconnect == true) await _connectPc();
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => LanviSendFilesPage(pairing: pairing!)),
    );
    await _refreshConnection();
  }

  void _receiveFromPcNotice() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PC → phone receiving'),
        content: const Text('The current Phase 02 PC bridge implements phone → PC uploads and Chrome downloads. We will add the PC → phone receive route when the bridge supports outgoing-file listing and download requests. This action is not presented as working yet.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Understood'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = LanviThemeCatalog.themes.entries
        .firstWhere(
          (entry) => entry.value.accent == Theme.of(context).colorScheme.primary,
          orElse: () => MapEntry(LanviThemeId.defaultEmerald, LanviThemeCatalog.byId(LanviThemeId.defaultEmerald)),
        )
        .value;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.pageHorizontal,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: AppRadius.small,
                border: Border.all(color: palette.border.withOpacity(0.8)),
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: Image.asset(
                'Assets/lanvi-symbol.png',
                width: 38,
                height: 38,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: palette.accent,
                  alignment: Alignment.center,
                  child: Text(
                    'L',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: palette.onAccent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            const Text('lanvi'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh PC connection',
            onPressed: _refreshConnection,
            icon: AnimatedRotation(
              turns: _checkingPc ? 0.5 : 0,
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
              child: Icon(PhosphorIcons.arrowsClockwise(PhosphorIconsStyle.light)),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
            icon: Icon(PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.light)),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            _LanviDashboardBody(
              username: _username,
              avatarSeed: _avatarSeed,
              palette: palette,
              isCheckingPc: _checkingPc,
              pcOnline: _pcOnline,
              pairing: _pairing,
              connectionLatencyMs: _connectionLatencyMs,
              lastUploadMegabytesPerSecond: _lastUploadMegabytesPerSecond,
              onRefresh: _refreshConnection,
              onConnect: _connectPc,
              onSend: _sendFiles,
              onReceive: _receiveFromPcNotice,
              onHistory: () => setState(() => _selectedIndex = 1),
            ),
            const HistoryPage(),
            const DevicesPage(),
            const MediaLibraryPage(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: [
          NavigationDestination(
            icon: Icon(PhosphorIcons.house(PhosphorIconsStyle.light)),
            selectedIcon: Icon(PhosphorIcons.house(PhosphorIconsStyle.regular)),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.light)),
            selectedIcon: Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.regular)),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(PhosphorIcons.devices(PhosphorIconsStyle.light)),
            selectedIcon: Icon(PhosphorIcons.devices(PhosphorIconsStyle.regular)),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(PhosphorIcons.musicNotes(PhosphorIconsStyle.light)),
            selectedIcon: Icon(PhosphorIcons.musicNotes(PhosphorIconsStyle.regular)),
            label: 'Media',
          ),
        ],
      ),
    );
  }
}

class _LanviDashboardBody extends StatelessWidget {
  const _LanviDashboardBody({
    required this.username,
    required this.avatarSeed,
    required this.palette,
    required this.isCheckingPc,
    required this.pcOnline,
    required this.pairing,
    required this.connectionLatencyMs,
    required this.lastUploadMegabytesPerSecond,
    required this.onRefresh,
    required this.onConnect,
    required this.onSend,
    required this.onReceive,
    required this.onHistory,
  });

  final String username;
  final String avatarSeed;
  final LanviThemeDefinition palette;
  final bool isCheckingPc;
  final bool pcOnline;
  final LanviPairing? pairing;
  final int? connectionLatencyMs;
  final double? lastUploadMegabytesPerSecond;
  final Future<void> Function() onRefresh;
  final VoidCallback onConnect;
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final connectedLabel = isCheckingPc
        ? 'Checking PC…'
        : pcOnline
            ? 'PC receiver reachable'
            : pairing == null
                ? 'PC not connected'
                : 'PC saved · not reachable';
    final connectedDetail = pcOnline
        ? '${pairing!.host}:${pairing!.port} · Local network'
        : pairing == null
            ? 'Scan the QR code in Lanvi Receiver for Chrome'
            : 'Check the bridge or scan a fresh QR code';

    final signalLevel = _resolveSignalLevel();
    final signalLabel = _resolveSignalLabel();
    final signalMetric = _resolveSignalMetric();

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: palette.accent,
      backgroundColor: palette.surface,
      displacement: 56,
      edgeOffset: 4,
      strokeWidth: 2.4,
      triggerMode: RefreshIndicatorTriggerMode.onEdge,
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(AppSpacing.pageHorizontal, AppSpacing.sm, AppSpacing.pageHorizontal, AppSpacing.xl),
        children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Good to see you,', style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(username, style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            ClipOval(
              child: Image.network(
                AvatarService.urlFor(avatarSeed),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 48,
                  height: 48,
                  color: palette.surface,
                  alignment: Alignment.center,
                  child: Text(username.isEmpty ? 'L' : username.characters.first.toUpperCase(), style: textTheme.titleLarge),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          decoration: BoxDecoration(color: palette.structure, borderRadius: AppRadius.large),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(PhosphorIcons.arrowsLeftRight(PhosphorIconsStyle.light), color: palette.onStructure, size: 24),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text('Your devices, in sync.', style: textTheme.titleMedium?.copyWith(color: palette.onStructure, fontWeight: FontWeight.w700))),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Send original files across your local network. No cloud transfer.',
                style: textTheme.bodyMedium?.copyWith(color: palette.onStructure.withOpacity(0.76), height: 1.45),
              ),
              const SizedBox(height: AppSpacing.md),
              GlassPanel(
                child: Row(
                  children: [
                    Icon(PhosphorIcons.monitor(PhosphorIconsStyle.light), color: palette.onStructure, size: 24),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(connectedLabel, style: textTheme.titleSmall?.copyWith(color: palette.onStructure, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(connectedDetail, style: textTheme.bodySmall?.copyWith(color: palette.onStructure.withOpacity(0.76))),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _WifiSignalIndicator(
                          level: signalLevel,
                          inactiveColor: const Color(0xFF9CA3AF),
                        ),
                        const SizedBox(height: 2),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: Text(
                            signalLabel,
                            key: ValueKey<String>(signalLabel),
                            style: textTheme.labelSmall?.copyWith(
                              color: signalLevel > 0 ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (signalMetric.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            signalMetric,
                            style: textTheme.labelSmall?.copyWith(
                              color: palette.onStructure.withOpacity(0.64),
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: palette.onStructure, side: BorderSide(color: palette.onStructure.withOpacity(0.28))),
                  onPressed: isCheckingPc ? null : onConnect,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(pairing == null ? 'Connect PC with QR code' : 'Pair / reconnect PC'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Quick actions', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _LanviActionCard(
                icon: PhosphorIcons.fileArrowUp(PhosphorIconsStyle.light),
                title: 'Send files',
                subtitle: 'Phone to PC',
                onTap: onSend,
                palette: palette,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _LanviActionCard(
                icon: PhosphorIcons.fileArrowDown(PhosphorIconsStyle.light),
                title: 'Receive files',
                subtitle: 'PC to phone · next phase',
                onTap: onReceive,
                palette: palette,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(color: scheme.surface, border: Border.all(color: scheme.outlineVariant), borderRadius: AppRadius.large),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: scheme.primary.withOpacity(0.10), borderRadius: AppRadius.medium),
                alignment: Alignment.center,
                child: Icon(PhosphorIcons.shieldCheck(PhosphorIconsStyle.light), size: 24, color: scheme.primary),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('File integrity is checked', style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Lanvi compares the source SHA-256 with the hash returned by your PC bridge.', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        TextButton.icon(
          onPressed: onHistory,
          icon: Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.light)),
          label: const Text('View sharing history'),
        ),
        ],
      ),
    );
  }

  int _resolveSignalLevel() {
    // Stay gray until a real upload rate has been measured. Health latency only
    // tells us that the PC answers; it does not measure transfer throughput.
    if (isCheckingPc || !pcOnline) return 0;

    final measuredRate = lastUploadMegabytesPerSecond;
    if (measuredRate == null || !measuredRate.isFinite || measuredRate <= 0) {
      return 0;
    }

    // Four visual steps based on the latest verified upload throughput.
    if (measuredRate >= 15) return 4;
    if (measuredRate >= 5) return 3;
    if (measuredRate >= 1) return 2;
    return 1;
  }

  String _resolveSignalLabel() {
    if (isCheckingPc) return 'Checking';
    if (!pcOnline) return 'Offline';

    final rate = lastUploadMegabytesPerSecond;
    if (rate == null || !rate.isFinite || rate <= 0) return 'Awaiting transfer';
    if (rate >= 15) return 'Excellent';
    if (rate >= 5) return 'Strong';
    if (rate >= 1) return 'Good';
    return 'Slow';
  }

  String _resolveSignalMetric() {
    if (!pcOnline || isCheckingPc) return '';
    final rate = lastUploadMegabytesPerSecond;
    if (rate == null || !rate.isFinite || rate <= 0) return 'Send a file to measure';
    return '${rate.toStringAsFixed(rate >= 10 ? 0 : 1)} MB/s';
  }
}

class _LanviActionCard extends StatefulWidget {
  const _LanviActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.palette,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final LanviThemeDefinition palette;

  @override
  State<_LanviActionCard> createState() => _LanviActionCardState();
}

class _LanviActionCardState extends State<_LanviActionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final palette = widget.palette;
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: Material(
        color: palette.surface,
        borderRadius: AppRadius.large,
        child: InkWell(
          borderRadius: AppRadius.large,
          onTap: widget.onTap,
          onHighlightChanged: (value) {
            if (mounted && value != _pressed) setState(() => _pressed = value);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              borderRadius: AppRadius.large,
              border: Border.all(color: _pressed ? palette.accent.withOpacity(0.65) : palette.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: palette.accent.withOpacity(0.10), borderRadius: AppRadius.medium),
                alignment: Alignment.center,
                child: Icon(widget.icon, size: 26, color: palette.accent),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(widget.title, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: palette.text)),
              const SizedBox(height: 4),
              Text(widget.subtitle, style: textTheme.bodySmall?.copyWith(color: palette.mutedText)),
            ],
            ),
          ),
        ),
      ),
    );
  }
}


/// A four-step Wi-Fi signal indicator. All arcs are gray by default; green
/// arcs are revealed only when a successful upload has measured throughput.
class _WifiSignalIndicator extends StatelessWidget {
  const _WifiSignalIndicator({required this.level, required this.inactiveColor});

  final int level;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    final safeLevel = level.clamp(0, 4);
    return Semantics(
      label: safeLevel == 0
          ? 'Local transfer speed not measured'
          : 'Measured local transfer signal, $safeLevel out of 4',
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: safeLevel.toDouble()),
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        builder: (context, strength, _) => CustomPaint(
          size: const Size(40, 36),
          painter: _WifiSignalPainter(
            strength: strength,
            activeColor: const Color(0xFF22C55E),
            inactiveColor: inactiveColor,
          ),
        ),
      ),
    );
  }
}

class _WifiSignalPainter extends CustomPainter {
  const _WifiSignalPainter({
    required this.strength,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double strength;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 40;
    final sy = size.height / 36;

    // Inner-to-outer ordering ensures level 1 begins with the small lower arc,
    // then fills each surrounding arc as throughput rises.
    final paths = <Path>[
      Path()
        ..moveTo(14 * sx, 25 * sy)
        ..quadraticBezierTo(20 * sx, 20 * sy, 26 * sx, 25 * sy),
      Path()
        ..moveTo(10 * sx, 21 * sy)
        ..quadraticBezierTo(20 * sx, 13 * sy, 30 * sx, 21 * sy),
      Path()
        ..moveTo(6 * sx, 17 * sy)
        ..quadraticBezierTo(20 * sx, 6.5 * sy, 34 * sx, 17 * sy),
      Path()
        ..moveTo(2 * sx, 13 * sy)
        ..quadraticBezierTo(20 * sx, -1 * sy, 38 * sx, 13 * sy),
    ];

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.55
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    for (var index = 0; index < paths.length; index++) {
      final path = paths[index];
      canvas.drawPath(path, inactivePaint);

      final progress = (strength - index).clamp(0.0, 1.0).toDouble();
      if (progress <= 0) continue;

      // PathMetrics is consumed through one iterator. Do not call isEmpty and
      // then first on the same PathMetrics sequence: that caused repeated
      // Bad state: No element exceptions during rebuilds on some runtimes.
      final metricIterator = path.computeMetrics().iterator;
      if (!metricIterator.moveNext()) continue;
      final metric = metricIterator.current;
      canvas.drawPath(metric.extractPath(0, metric.length * progress), activePaint);
    }

    final center = Offset(20 * sx, 31 * sy);
    final baseRadius = 2.05 * (sx < sy ? sx : sy);
    canvas.drawCircle(center, baseRadius, Paint()..color = inactiveColor);
    final dotProgress = strength.clamp(0.0, 1.0).toDouble();
    if (dotProgress > 0) {
      canvas.drawCircle(
        center,
        baseRadius * dotProgress,
        Paint()..color = activeColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WifiSignalPainter oldDelegate) =>
      oldDelegate.strength != strength ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}
