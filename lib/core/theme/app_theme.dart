// Purpose: Converts Lanvi's semantic theme tokens into Flutter ThemeData.
// How to use: MaterialApp calls AppTheme.build with the active theme and font.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — defines typography, controls, outlines and no-shadow surfaces.

import 'package:flutter/material.dart';

import '../style/app_radius.dart';
import 'font_catalog.dart';
import 'theme_catalog.dart';

class AppTheme {
  AppTheme._();

  static ThemeData build({
    required LanviThemeDefinition definition,
    required LanviFontDefinition font,
  }) {
    final brightness = definition.isDark ? Brightness.dark : Brightness.light;
    final baseTheme = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: definition.accent,
        brightness: brightness,
      ).copyWith(
        primary: definition.accent,
        onPrimary: definition.onAccent,
        secondary: definition.structure,
        onSecondary: definition.onStructure,
        surface: definition.canvas,
        onSurface: definition.text,
        onSurfaceVariant: definition.mutedText,
        outline: definition.border,
        outlineVariant: definition.border,
        surfaceTint: Colors.transparent,
      ),
      scaffoldBackgroundColor: definition.canvas,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    final textTheme = LanviFontCatalog.resolveTextTheme(font, baseTheme.textTheme)
        .apply(
          bodyColor: definition.text,
          displayColor: definition.text,
        );

    final borderRadius = BorderRadius.circular(AppRadius.md);
    final outlineBorder = OutlineInputBorder(
      borderRadius: borderRadius,
      borderSide: BorderSide(color: definition.border, width: 1),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: borderRadius,
      borderSide: BorderSide(color: definition.accent, width: 1.5),
    );

    return baseTheme.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme.apply(
        bodyColor: definition.onStructure,
        displayColor: definition.onStructure,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: definition.canvas,
        foregroundColor: definition.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: definition.text,
          fontWeight: FontWeight.w700,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: definition.border,
        thickness: 1,
        space: 24,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: definition.surface,
        hintStyle: textTheme.bodyMedium?.copyWith(color: definition.mutedText),
        labelStyle: textTheme.bodyMedium?.copyWith(color: definition.mutedText),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: outlineBorder,
        enabledBorder: outlineBorder,
        focusedBorder: focusedBorder,
        errorBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: const BorderSide(color: Color(0xFFB42318), width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: const BorderSide(color: Color(0xFFB42318), width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: definition.accent,
          foregroundColor: definition.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: definition.text,
          side: BorderSide(color: definition.border, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: definition.accent,
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: definition.canvas,
        indicatorColor: definition.accent.withOpacity(0.12),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected ? definition.accent : definition.mutedText,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: definition.structure,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: definition.onStructure,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: definition.accent,
        textColor: definition.text,
        tileColor: Colors.transparent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}
