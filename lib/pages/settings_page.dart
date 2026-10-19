// Purpose: Allows the user to switch between Lanvi themes and font families.
// How to use: Open from the home dashboard; changes are applied and persisted immediately.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds selectors for all 10 themes and 11 font families.

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../core/style/glass_panel.dart';
import '../core/theme/font_catalog.dart';
import '../core/theme/theme_catalog.dart';
import '../core/theme/theme_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final palette = controller.currentThemeDefinition;
    final font = controller.currentFontDefinition;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: Icon(PhosphorIcons.arrowLeft(PhosphorIconsStyle.light)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        children: [
          Text(
            'Your workspace, your way.',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Theme and font choices are saved locally and apply across Lanvi.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.mutedText),
          ),
          const SizedBox(height: AppSpacing.lg),
          _SectionHeading(
            icon: PhosphorIcons.palette(PhosphorIconsStyle.light),
            title: 'Color theme',
            detail: '10 solid-color presets',
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<LanviThemeId>(
            value: controller.themeId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Active theme'),
            items: LanviThemeCatalog.themes.entries.map((entry) {
              return DropdownMenuItem<LanviThemeId>(
                value: entry.key,
                child: Text(entry.value.name),
              );
            }).toList(),
            onChanged: (id) {
              if (id != null) controller.setTheme(id);
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(palette.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.mutedText)),
          const SizedBox(height: AppSpacing.lg),
          _ThemeSwatches(controller: controller),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeading(
            icon: PhosphorIcons.textAa(PhosphorIconsStyle.light),
            title: 'Typography',
            detail: '11 font options',
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<LanviFontId>(
            value: controller.fontId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Font family'),
            items: LanviFontCatalog.fonts.map((fontDefinition) {
              return DropdownMenuItem<LanviFontId>(
                value: fontDefinition.id,
                child: Text(fontDefinition.name),
              );
            }).toList(),
            onChanged: (id) {
              if (id != null) controller.setFont(id);
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(font.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.mutedText)),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(color: palette.border),
              borderRadius: AppRadius.large,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Lanvi transfer', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Files will move over your local network. Theme and typography settings are separate from the transfer path.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.mutedText, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: palette.structure,
              borderRadius: AppRadius.large,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Minimal Glass preview', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: palette.onStructure, fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.sm),
                GlassPanel(
                  child: Row(
                    children: [
                      Icon(PhosphorIcons.wifiHigh(PhosphorIconsStyle.light), color: palette.onStructure),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Focused glass surface · 20 px blur · 12% white fill',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.onStructure),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: controller.resetToDefaults,
            icon: Icon(PhosphorIcons.arrowCounterClockwise(PhosphorIconsStyle.light)),
            label: const Text('Reset appearance'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Note: Satoshi and SF Pro need platform support or bundled font assets for exact rendering. Google Fonts options may fetch typography files unless those assets are bundled; this is not part of Lanvi file transfer.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.mutedText),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: palette.primary, size: 24),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(detail, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThemeSwatches extends StatelessWidget {
  const _ThemeSwatches({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      itemCount: LanviThemeCatalog.themes.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: 2.3,
      ),
      itemBuilder: (context, index) {
        final entry = LanviThemeCatalog.themes.entries.elementAt(index);
        final theme = entry.value;
        final selected = controller.themeId == entry.key;
        return Material(
          color: theme.canvas,
          borderRadius: AppRadius.medium,
          child: InkWell(
            borderRadius: AppRadius.medium,
            onTap: () => controller.setTheme(entry.key),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: AppRadius.medium,
                border: Border.all(
                  color: selected ? theme.accent : theme.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Swatch(color: theme.canvas),
                      const SizedBox(height: 3),
                      _Swatch(color: theme.structure),
                      const SizedBox(height: 3),
                      _Swatch(color: theme.accent),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      theme.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: theme.text,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(PhosphorIcons.checkCircle(PhosphorIconsStyle.fill), color: theme.accent, size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black.withOpacity(0.10), width: 1),
      ),
    );
  }
}
