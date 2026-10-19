// Purpose: Stores the lightweight local profile used by the Phase 01 screens.
// How to use: Use these methods from profile and home pages; no account/server is required.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — persists username and chosen avatar seed locally.

import 'package:shared_preferences/shared_preferences.dart';

class ProfileService {
  ProfileService._();

  static const String _usernameKey = 'lanvi.profile.username.v1';
  static const String _avatarSeedKey = 'lanvi.profile.avatar_seed.v1';

  static Future<bool> hasProfile() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final username = preferences.getString(_usernameKey)?.trim() ?? '';
      return username.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveProfile({
    required String username,
    required String avatarSeed,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_usernameKey, username.trim());
    await preferences.setString(_avatarSeedKey, avatarSeed);
  }

  static Future<String> getUsername() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(_usernameKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getAvatarSeed() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(_avatarSeedKey) ?? 'Lanvi';
    } catch (_) {
      return 'Lanvi';
    }
  }
}
