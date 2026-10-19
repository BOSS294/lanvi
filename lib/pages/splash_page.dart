// Purpose: Premium animated Lanvi splash and first-launch route selection.
// How to use: This page is MaterialApp.home and routes to profile setup or home after the reveal.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds a restrained logo reveal and local profile check.

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../core/theme/theme_catalog.dart';
import '../services/profile_service.dart';
import 'home_page.dart';
import 'profile_setup_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _animationController.forward();
    _continueAfterReveal();
  }

  Future<void> _continueAfterReveal() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    final hasProfile = await ProfileService.hasProfile();
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            hasProfile ? const HomePage() : const ProfileSetupPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 240),
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = LanviThemeCatalog.byId(_activeThemeId(context));

    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: AppRadius.large,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    PhosphorIcons.arrowsLeftRight(PhosphorIconsStyle.light),
                    color: palette.onAccent,
                    size: 32,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'lanvi',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.6,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Local sharing. Effortless workflow.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Resolve the selected definition from its current theme brightness and
  // accent-independent platform tokens. This helper keeps the splash simple.
  LanviThemeId _activeThemeId(BuildContext context) {
    // ThemeData's primary color is the theme's accent; use it to identify the
    // active catalogue entry without introducing another global dependency.
    final primary = Theme.of(context).colorScheme.primary;
    for (final entry in LanviThemeCatalog.themes.entries) {
      if (entry.value.accent == primary) return entry.key;
    }
    return LanviThemeId.defaultEmerald;
  }
}
