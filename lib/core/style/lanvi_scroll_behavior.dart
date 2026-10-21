/*
 * Purpose: Provide consistent, smooth scrolling across Lanvi's mobile screens.
 * How to use: Register as MaterialApp.scrollBehavior in lib/main.dart.
 * Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
 * Changelog: 1.5.0 — enables natural bounce physics and removes the default overscroll glow.
 */

import 'package:flutter/material.dart';

class LanviScrollBehavior extends MaterialScrollBehavior {
  const LanviScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Keep the experience calm and premium; RefreshIndicator supplies its own feedback.
    return child;
  }
}
