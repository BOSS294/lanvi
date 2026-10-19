// Purpose: Empty-state UI for Lanvi's sharing history tab.
// How to use: Render inside HomePage's IndexedStack; replace the empty state when history is wired in Phase 06.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds an intentional history empty state.

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
      children: [
        Text('Sharing history', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'A clear record of files sent and received on this device.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xl),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.outlineVariant),
            borderRadius: AppRadius.large,
          ),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: palette.primary.withOpacity(0.10),
                  borderRadius: AppRadius.large,
                ),
                alignment: Alignment.center,
                child: Icon(
                  PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.light),
                  size: 32,
                  color: palette.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Nothing shared yet', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Completed and interrupted transfers will appear here once the transfer engine is connected.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
