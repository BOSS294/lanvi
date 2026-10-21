// Purpose: App entry point with global theme/font wiring and Android share-intent initialization.
// How to use: Replace the existing lib/main.dart contents with this version after adding the share-intent dependency.
// Project: Lanvi | Release: 1.5.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Registers smooth scrolling, Android share intents and local mDNS device discovery.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/style/lanvi_scroll_behavior.dart';
import 'pages/splash_page.dart';
import 'services/lanvi_share_intent_service.dart';
import 'services/lanvi_device_discovery_service.dart';
import 'services/lanvi_media_library_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeController = ThemeController();
  await themeController.load();
  await LanviShareIntentService.instance.initialize();
  await LanviMediaLibraryService.instance.loadPreferences();
  // Discovery failure must never prevent the app UI or file sending from opening.
  unawaited(LanviDeviceDiscoveryService.instance.start());

  runApp(
    ChangeNotifierProvider<ThemeController>.value(
      value: themeController,
      child: const LanviApp(),
    ),
  );
}

class LanviApp extends StatelessWidget {
  const LanviApp({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();

    return MaterialApp(
      title: 'Lanvi',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const LanviScrollBehavior(),
      theme: AppTheme.build(
        definition: controller.currentThemeDefinition,
        font: controller.currentFontDefinition,
      ),
      home: const SplashPage(),
    );
  }
}
