// Purpose: Responsive, animated Lanvi splash screen using the official full wordmark asset.
// How to use: Copy this file's contents into lib/pages/splash_page.dart so the existing main.dart import remains valid.
// Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.5.0 — uses Assets/lanvi-logo.png, respects narrow/short screens, and preserves first-launch routing.

import 'dart:math' as math;

import 'package:flutter/material.dart';

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

  static const Color _brandGreen = Color(0xFF0F3D26);
  static const double _logoAspectWidth = 695;
  static const double _logoAspectHeight = 780;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    );

    _scaleAnimation = Tween<double>(begin: 0.965, end: 1).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    _animationController.forward();
    _continueAfterReveal();
  }

  Future<void> _continueAfterReveal() async {
    // Keep the complete wordmark visible long enough to register on launch.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    final hasProfile = await ProfileService.hasProfile();
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            hasProfile ? const HomePage() : const ProfileSetupPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
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
    return Scaffold(
      // The supplied wordmark has a white background, so a white canvas makes
      // the image edges disappear cleanly rather than showing a white tile.
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = math.max(0.0, constraints.maxWidth - 48.0).toDouble();
            final maxLogoHeight = math.min(390.0, constraints.maxHeight * 0.55).toDouble();
            final widthAllowedByHeight =
                maxLogoHeight * (_logoAspectWidth / _logoAspectHeight);
            final logoWidth = math.min(
              math.min(330.0, availableWidth),
              widthAllowedByHeight,
            ).toDouble();
            final logoHeight = logoWidth * (_logoAspectHeight / _logoAspectWidth);

            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(0.0, constraints.maxHeight - 64.0).toDouble(),
                  ),
                  child: Center(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: ScaleTransition(
                        scale: _scaleAnimation,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Image.asset(
                              'Assets/lanvi-logo.png',
                              width: logoWidth,
                              height: logoHeight,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              semanticLabel: 'Lanvi',
                              errorBuilder: (context, error, stackTrace) {
                                // Keep launch usable if the asset path is not
                                // registered yet; the debug console exposes the
                                // underlying asset error for easy correction.
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset(
                                      'Assets/lanvi-symbol.png',
                                      width: 112,
                                      height: 112,
                                      fit: BoxFit.contain,
                                      errorBuilder: (context, symbolError, symbolStack) => const Icon(
                                        Icons.swap_horiz_rounded,
                                        size: 72,
                                        color: _brandGreen,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      'LANVI',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _brandGreen,
                                        fontSize: 32,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 7,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 24),
                            Text(
                              'LOCAL SHARING. EFFORTLESS WORKFLOW.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: _brandGreen,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 32),
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: _brandGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
