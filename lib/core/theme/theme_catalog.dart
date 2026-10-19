// Purpose: Central catalogue of Lanvi's ten solid-color themes and semantic tokens.
// How to use: Read LanviThemeCatalog.byId(id) instead of hard-coding colors in pages.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — defines the 10 requested theme presets and default 60/30/10 palette.

import 'package:flutter/material.dart';

enum LanviThemeId {
  defaultEmerald,
  darkForest,
  minimalTech,
  monoDark,
  nordAlpine,
  obsidianRose,
  creamCocoa,
  cyberPunk,
  slateMinimal,
  tokyoNight,
}

class LanviThemeDefinition {
  const LanviThemeDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.canvas,
    required this.structure,
    required this.accent,
    required this.text,
    required this.mutedText,
    required this.surface,
    required this.border,
    required this.onStructure,
    required this.onAccent,
    required this.isDark,
  });

  final LanviThemeId id;
  final String name;
  final String description;
  final Color canvas;
  final Color structure;
  final Color accent;
  final Color text;
  final Color mutedText;
  final Color surface;
  final Color border;
  final Color onStructure;
  final Color onAccent;
  final bool isDark;
}

class LanviThemeCatalog {
  LanviThemeCatalog._();

  static const Map<LanviThemeId, LanviThemeDefinition> themes = {
    LanviThemeId.defaultEmerald: LanviThemeDefinition(
      id: LanviThemeId.defaultEmerald,
      name: 'Default Emerald',
      description: 'White canvas, black structure and deep-green accents.',
      canvas: Color(0xFFFFFFFF),
      structure: Color(0xFF000000),
      accent: Color(0xFF0F3D26),
      text: Color(0xFF000000),
      mutedText: Color(0xFF5D625F),
      surface: Color(0xFFF7F8F7),
      border: Color(0xFFE0E4E1),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFFFFFFFF),
      isDark: false,
    ),
    LanviThemeId.darkForest: LanviThemeDefinition(
      id: LanviThemeId.darkForest,
      name: 'Dark Forest',
      description: 'Deep forest surfaces with restrained sage accents.',
      canvas: Color(0xFF0C1510),
      structure: Color(0xFF14261B),
      accent: Color(0xFF8DB99A),
      text: Color(0xFFF2F6F2),
      mutedText: Color(0xFFB2BFB5),
      surface: Color(0xFF16231A),
      border: Color(0xFF2B3B30),
      onStructure: Color(0xFFF6FAF6),
      onAccent: Color(0xFF0C1510),
      isDark: true,
    ),
    LanviThemeId.minimalTech: LanviThemeDefinition(
      id: LanviThemeId.minimalTech,
      name: 'Minimal Tech',
      description: 'Near-white neutrals with a controlled teal action color.',
      canvas: Color(0xFFF8F8F6),
      structure: Color(0xFF20221F),
      accent: Color(0xFF0F766E),
      text: Color(0xFF20221F),
      mutedText: Color(0xFF676B66),
      surface: Color(0xFFFFFFFF),
      border: Color(0xFFE2E5E0),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFFFFFFFF),
      isDark: false,
    ),
    LanviThemeId.monoDark: LanviThemeDefinition(
      id: LanviThemeId.monoDark,
      name: 'Mono Dark',
      description: 'A strict graphite monochrome interface.',
      canvas: Color(0xFF111111),
      structure: Color(0xFF242424),
      accent: Color(0xFFF3F3F3),
      text: Color(0xFFFAFAFA),
      mutedText: Color(0xFFB5B5B5),
      surface: Color(0xFF191919),
      border: Color(0xFF343434),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFF000000),
      isDark: true,
    ),
    LanviThemeId.nordAlpine: LanviThemeDefinition(
      id: LanviThemeId.nordAlpine,
      name: 'Nord Alpine',
      description: 'Cool alpine neutrals with a muted arctic accent.',
      canvas: Color(0xFFECEFF4),
      structure: Color(0xFF2E3440),
      accent: Color(0xFF5E81AC),
      text: Color(0xFF2E3440),
      mutedText: Color(0xFF4C566A),
      surface: Color(0xFFF6F7FA),
      border: Color(0xFFD8DEE9),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFFFFFFFF),
      isDark: false,
    ),
    LanviThemeId.obsidianRose: LanviThemeDefinition(
      id: LanviThemeId.obsidianRose,
      name: 'Obsidian Rose',
      description: 'Dark obsidian layers with a restrained rose highlight.',
      canvas: Color(0xFF121114),
      structure: Color(0xFF252127),
      accent: Color(0xFFD69CAD),
      text: Color(0xFFF6F0F3),
      mutedText: Color(0xFFC3B6BD),
      surface: Color(0xFF1B191E),
      border: Color(0xFF39323A),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFF20151A),
      isDark: true,
    ),
    LanviThemeId.creamCocoa: LanviThemeDefinition(
      id: LanviThemeId.creamCocoa,
      name: 'Cream Cocoa',
      description: 'Warm cream and cocoa with a clay accent.',
      canvas: Color(0xFFFBF4E8),
      structure: Color(0xFF4A3428),
      accent: Color(0xFFA45A3F),
      text: Color(0xFF3A2B23),
      mutedText: Color(0xFF78675C),
      surface: Color(0xFFFFF9F0),
      border: Color(0xFFE6D9C8),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFFFFFFFF),
      isDark: false,
    ),
    LanviThemeId.cyberPunk: LanviThemeDefinition(
      id: LanviThemeId.cyberPunk,
      name: 'Cyber Punk',
      description: 'Flat black and graphite with one controlled neon accent.',
      canvas: Color(0xFF0D0D0D),
      structure: Color(0xFF202020),
      accent: Color(0xFFC8FF00),
      text: Color(0xFFF5F7EC),
      mutedText: Color(0xFFB8C0A0),
      surface: Color(0xFF151515),
      border: Color(0xFF32382A),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFF0D0D0D),
      isDark: true,
    ),
    LanviThemeId.slateMinimal: LanviThemeDefinition(
      id: LanviThemeId.slateMinimal,
      name: 'Slate Minimal',
      description: 'Quiet slate structure over a pale neutral canvas.',
      canvas: Color(0xFFF1F5F9),
      structure: Color(0xFF334155),
      accent: Color(0xFF0F172A),
      text: Color(0xFF0F172A),
      mutedText: Color(0xFF64748B),
      surface: Color(0xFFFFFFFF),
      border: Color(0xFFDCE4EC),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFFFFFFFF),
      isDark: false,
    ),
    LanviThemeId.tokyoNight: LanviThemeDefinition(
      id: LanviThemeId.tokyoNight,
      name: 'Tokyo Night',
      description: 'Night-sky charcoal with a measured violet accent.',
      canvas: Color(0xFF1A1B26),
      structure: Color(0xFF24283B),
      accent: Color(0xFFBB9AF7),
      text: Color(0xFFC0CAF5),
      mutedText: Color(0xFFA9B1D6),
      surface: Color(0xFF202234),
      border: Color(0xFF343A54),
      onStructure: Color(0xFFFFFFFF),
      onAccent: Color(0xFF1A1B26),
      isDark: true,
    ),
  };

  static LanviThemeDefinition byId(LanviThemeId id) => themes[id]!;

  static LanviThemeId fromStoredName(String? name) {
    return LanviThemeId.values.firstWhere(
      (candidate) => candidate.name == name,
      orElse: () => LanviThemeId.defaultEmerald,
    );
  }
}
