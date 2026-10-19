// Purpose: First-run username and avatar setup for Lanvi.
// How to use: SplashPage opens this page when a local profile has not been saved.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds local profile setup, seeded avatar choices and offline fallbacks.

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../core/theme/theme_catalog.dart';
import '../services/avatar_service.dart';
import '../services/profile_service.dart';
import 'home_page.dart';

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  String _selectedSeed = AvatarService.suggestedSeeds.first;
  bool _isSaving = false;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      await ProfileService.saveProfile(
        username: _usernameController.text,
        avatarSeed: _selectedSeed,
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
        (_) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the profile. Please retry.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
        title: const Text('Set up your profile'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: palette.structure,
                  borderRadius: AppRadius.large,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      PhosphorIcons.userCircle(PhosphorIconsStyle.light),
                      size: 32,
                      color: palette.onStructure,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Make Lanvi yours.',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: palette.onStructure,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Choose how your trusted devices identify you.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.onStructure.withOpacity(0.76),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('Username', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              TextFormField(
                controller: _usernameController,
                textCapitalization: TextCapitalization.words,
                maxLength: 24,
                decoration: const InputDecoration(
                  hintText: 'e.g. Mayank',
                  prefixIcon: Icon(PhosphorIcons.user(PhosphorIconsStyle.light)),
                  counterText: '',
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Enter a username to continue.';
                  if (text.length < 2) return 'Use at least 2 characters.';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Choose an avatar', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Seeded avatars are optional. If the avatar service is unavailable, Lanvi uses a local fallback.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: AvatarService.suggestedSeeds.map((seed) {
                  final selected = seed == _selectedSeed;
                  return Semantics(
                    button: true,
                    selected: selected,
                    label: 'Avatar $seed',
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedSeed = seed),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          borderRadius: AppRadius.large,
                          border: Border.all(
                            color: selected ? palette.accent : palette.border,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: AppRadius.medium,
                              child: Image.network(
                                AvatarService.urlFor(seed),
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                  width: 56,
                                  height: 56,
                                  color: palette.surface,
                                  alignment: Alignment.center,
                                  child: Text(
                                    seed.characters.first.toUpperCase(),
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(seed, style: Theme.of(context).textTheme.labelSmall),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: _isSaving ? null : _continue,
                icon: _isSaving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(PhosphorIcons.arrowRight(PhosphorIconsStyle.light)),
                label: Text(_isSaving ? 'Saving profile…' : 'Continue to Lanvi'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Your profile is stored on this device. No account is required.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
