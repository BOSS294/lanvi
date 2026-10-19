// Purpose: Owns the selected Lanvi theme and font and persists both locally.
// How to use: Access with context.watch<ThemeController>() or context.read<ThemeController>().
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds saved theme/font preferences and default reset.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'font_catalog.dart';
import 'theme_catalog.dart';

class ThemeController extends ChangeNotifier {
  static const String _themePreferenceKey = 'lanvi.settings.theme.v1';
  static const String _fontPreferenceKey = 'lanvi.settings.font.v1';

  LanviThemeId _themeId = LanviThemeId.defaultEmerald;
  LanviFontId _fontId = LanviFontId.inter;
  bool _isLoaded = false;

  LanviThemeId get themeId => _themeId;
  LanviFontId get fontId => _fontId;
  LanviThemeDefinition get currentThemeDefinition =>
      LanviThemeCatalog.byId(_themeId);
  LanviFontDefinition get currentFontDefinition =>
      LanviFontCatalog.byId(_fontId);
  bool get isLoaded => _isLoaded;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _themeId = LanviThemeCatalog.fromStoredName(
        preferences.getString(_themePreferenceKey),
      );
      _fontId = LanviFontCatalog.fromStoredName(
        preferences.getString(_fontPreferenceKey),
      );
    } catch (_) {
      // Preferences are optional. Default tokens still let Lanvi start safely.
      _themeId = LanviThemeId.defaultEmerald;
      _fontId = LanviFontId.inter;
    }
    _isLoaded = true;
    notifyListeners();
  }

  void setTheme(LanviThemeId id) {
    if (_themeId == id) return;
    _themeId = id;
    notifyListeners();
    unawaited(_persistString(_themePreferenceKey, id.name));
  }

  void setFont(LanviFontId id) {
    if (_fontId == id) return;
    _fontId = id;
    notifyListeners();
    unawaited(_persistString(_fontPreferenceKey, id.name));
  }

  void resetToDefaults() {
    _themeId = LanviThemeId.defaultEmerald;
    _fontId = LanviFontId.inter;
    notifyListeners();
    unawaited(_persistDefaults());
  }

  Future<void> _persistDefaults() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _themePreferenceKey,
        LanviThemeId.defaultEmerald.name,
      );
      await preferences.setString(_fontPreferenceKey, LanviFontId.inter.name);
    } catch (_) {
      // A preference-write failure must not break the currently active UI.
    }
  }

  Future<void> _persistString(String key, String value) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(key, value);
    } catch (_) {
      // Theme and font changes remain active for the current session.
    }
  }
}
