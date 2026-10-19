// Purpose: Lanvi's primary dashboard with connection, send/receive, and activity navigation.
// How to use: Open after profile setup; transfer buttons are visual placeholders until Phase 06 integration.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds premium dashboard skeleton, GlassPanel usage, and navigation to history/settings.

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../core/style/glass_panel.dart';
import '../core/theme/theme_catalog.dart';
import '../services/avatar_service.dart';
import '../services/profile_service.dart';
import 'history_page.dart';
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

  @override
  void initState() {
    super.initState();
    _loadProfile();
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

  void _showPhaseNotice(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature will be connected in the transfer-engine phase.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = LanviThemeCatalog.themes.entries
        .firstWhere(
          (entry) => entry.value.accent == Theme.of(context).colorScheme.primary,
          orElse: () => MapEntry(
            LanviThemeId.defaultEmerald,
            LanviThemeCatalog.byId(LanviThemeId.defaultEmerald),
          ),
        )
        .value;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.pageHorizontal,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: AppRadius.small,
              ),
              alignment: Alignment.center,
              child: Text(
                'L',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: palette.onAccent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            const Text('lanvi'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
            icon: Icon(PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.light)),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            _DashboardBody(
              username: _username,
              avatarSeed: _avatarSeed,
              onSend: () => _showPhaseNotice('Send files'),
              onReceive: () => _showPhaseNotice('Receive files'),
              onViewHistory: () => setState(() => _selectedIndex = 1),
              palette: palette,
            ),
            const HistoryPage(),
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
        ],
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.username,
    required this.avatarSeed,
    required this.onSend,
    required this.onReceive,
    required this.onViewHistory,
    required this.palette,
  });

  final String username;
  final String avatarSeed;
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onViewHistory;
  final LanviThemeDefinition palette;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageHorizontal,
        AppSpacing.sm,
        AppSpacing.pageHorizontal,
        AppSpacing.xl,
      ),
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
                  child: Text(
                    username.isEmpty ? 'L' : username.characters.first.toUpperCase(),
                    style: textTheme.titleLarge,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          decoration: BoxDecoration(
            color: palette.structure,
            borderRadius: AppRadius.large,
          ),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    PhosphorIcons.arrowsLeftRight(PhosphorIconsStyle.light),
                    color: palette.onStructure,
                    size: 24,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Your devices, in sync.',
                    style: textTheme.titleMedium?.copyWith(
                      color: palette.onStructure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Send original files across your local network. No cloud transfer.',
                style: textTheme.bodyMedium?.copyWith(
                  color: palette.onStructure.withOpacity(0.76),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              GlassPanel(
                child: Row(
                  children: [
                    Icon(
                      PhosphorIcons.monitor(PhosphorIconsStyle.light),
                      color: palette.onStructure,
                      size: 24,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PC not connected',
                            style: textTheme.titleSmall?.copyWith(
                              color: palette.onStructure,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Pair from the Chrome extension',
                            style: textTheme.bodySmall?.copyWith(
                              color: palette.onStructure.withOpacity(0.76),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      PhosphorIcons.wifiSlash(PhosphorIconsStyle.light),
                      color: palette.onStructure,
                      size: 24,
                    ),
                  ],
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
              child: _ActionCard(
                icon: PhosphorIcons.fileArrowUp(PhosphorIconsStyle.light),
                title: 'Send files',
                subtitle: 'Phone to PC',
                onTap: onSend,
                palette: palette,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _ActionCard(
                icon: PhosphorIcons.fileArrowDown(PhosphorIconsStyle.light),
                title: 'Receive files',
                subtitle: 'PC to phone',
                onTap: onReceive,
                palette: palette,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(child: Text('Active transfers', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
            Text('0 active', style: textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.border),
            borderRadius: AppRadius.large,
          ),
          child: Row(
            children: [
              Icon(PhosphorIcons.checkCircle(PhosphorIconsStyle.light), color: palette.accent, size: 24),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ready when you are', style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      'Active progress and transfer details will appear here.',
                      style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(child: Text('Recent sharing', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
            TextButton(onPressed: onViewHistory, child: const Text('View history')),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            border: Border.all(color: palette.border),
            borderRadius: AppRadius.large,
          ),
          child: Column(
            children: [
              Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.light), size: 32, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.xs),
              Text('Your recent transfers will show up here.', textAlign: TextAlign.center, style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
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
  Widget build(BuildContext context) {
    return Material(
      color: palette.surface,
      borderRadius: AppRadius.large,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.large,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            border: Border.all(color: palette.border),
            borderRadius: AppRadius.large,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: palette.accent.withOpacity(0.10),
                  borderRadius: AppRadius.medium,
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: palette.accent, size: 24),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.mutedText)),
            ],
          ),
        ),
      ),
    );
  }
}
