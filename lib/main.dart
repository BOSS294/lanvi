// Purpose: App entry point and global theme/font wiring for Lanvi.
// How to use: Keep this as lib/main.dart; run `flutter pub get` then `flutter run`.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — registers ThemeController before rendering the app.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'pages/splash_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeController = ThemeController();
  await themeController.load();

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
      theme: AppTheme.build(
        definition: controller.currentThemeDefinition,
        font: controller.currentFontDefinition,
      ),
      home: const SplashPage(),
    );
  }
}
