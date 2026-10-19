// Purpose: Central font catalogue and active TextTheme resolver for Lanvi.
// How to use: ThemeController stores a LanviFontId; AppTheme resolves it through this file.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — defines the 11 requested font options and safe local/platform fallbacks.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum LanviFontId {
  inter,
  dmSans,
  satoshi,
  geistSans,
  plusJakartaSans,
  publicSans,
  sfPro,
  roboto,
  montserrat,
  workSans,
  poppins,
}

class LanviFontDefinition {
  const LanviFontDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.googleFontsFamily,
    required this.localFamily,
  });

  final LanviFontId id;
  final String name;
  final String description;
  final String? googleFontsFamily;
  final String localFamily;
}

class LanviFontCatalog {
  LanviFontCatalog._();

  static const List<LanviFontDefinition> fonts = [
    LanviFontDefinition(
      id: LanviFontId.inter,
      name: 'Inter',
      description: 'Neutral, highly legible interface default.',
      googleFontsFamily: 'Inter',
      localFamily: 'Inter',
    ),
    LanviFontDefinition(
      id: LanviFontId.dmSans,
      name: 'DM Sans',
      description: 'Friendly geometry with a polished feel.',
      googleFontsFamily: 'DM Sans',
      localFamily: 'DM Sans',
    ),
    LanviFontDefinition(
      id: LanviFontId.satoshi,
      name: 'Satoshi',
      description: 'Modern geometric family; add licensed local assets for exact rendering.',
      googleFontsFamily: null,
      localFamily: 'Satoshi',
    ),
    LanviFontDefinition(
      id: LanviFontId.geistSans,
      name: 'Geist Sans',
      description: 'Technical and precise.',
      googleFontsFamily: 'Geist',
      localFamily: 'Geist',
    ),
    LanviFontDefinition(
      id: LanviFontId.plusJakartaSans,
      name: 'Plus Jakarta Sans',
      description: 'Contemporary and refined.',
      googleFontsFamily: 'Plus Jakarta Sans',
      localFamily: 'Plus Jakarta Sans',
    ),
    LanviFontDefinition(
      id: LanviFontId.publicSans,
      name: 'Public Sans',
      description: 'Neutral and information-dense.',
      googleFontsFamily: 'Public Sans',
      localFamily: 'Public Sans',
    ),
    LanviFontDefinition(
      id: LanviFontId.sfPro,
      name: 'SF Pro / San Francisco',
      description: 'Platform-native feel; exact font availability depends on platform/assets.',
      googleFontsFamily: null,
      localFamily: '.SF Pro Text',
    ),
    LanviFontDefinition(
      id: LanviFontId.roboto,
      name: 'Roboto',
      description: 'Familiar and practical, especially on Android.',
      googleFontsFamily: 'Roboto',
      localFamily: 'Roboto',
    ),
    LanviFontDefinition(
      id: LanviFontId.montserrat,
      name: 'Montserrat',
      description: 'Distinct geometric character for strong headings.',
      googleFontsFamily: 'Montserrat',
      localFamily: 'Montserrat',
    ),
    LanviFontDefinition(
      id: LanviFontId.workSans,
      name: 'Work Sans',
      description: 'Clean and functional.',
      googleFontsFamily: 'Work Sans',
      localFamily: 'Work Sans',
    ),
    LanviFontDefinition(
      id: LanviFontId.poppins,
      name: 'Poppins',
      description: 'Geometric and expressive.',
      googleFontsFamily: 'Poppins',
      localFamily: 'Poppins',
    ),
  ];

  static LanviFontDefinition byId(LanviFontId id) =>
      fonts.firstWhere((font) => font.id == id);

  static LanviFontId fromStoredName(String? name) {
    return LanviFontId.values.firstWhere(
      (candidate) => candidate.name == name,
      orElse: () => LanviFontId.inter,
    );
  }

  static TextTheme resolveTextTheme(LanviFontDefinition font, TextTheme base) {
    final family = font.googleFontsFamily;
    if (family == null) {
      return base.apply(fontFamily: font.localFamily);
    }

    // Google Fonts options are a typography convenience only. They are not used
    // by Lanvi's local-network file-transfer path. Bundle font assets for a
    // fully offline release build if runtime font fetching is not desired.
    try {
      return GoogleFonts.getTextTheme(family, base);
    } catch (_) {
      // Keep the app usable if a font family is unavailable; fall back to the
      // requested platform family rather than preventing the app from starting.
      return base.apply(fontFamily: font.localFamily);
    }
  }
}
