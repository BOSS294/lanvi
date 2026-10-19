// Purpose: Supplies seeded avatar URLs for profile setup with no account or API key.
// How to use: AvatarService.urlFor(seed) returns a DiceBear PNG URL; UI must provide an offline fallback.
// Project: Lanvi | Version: 1.0.0 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: v1.0.0 — adds seed-based avatar options and documents the optional network dependency.

class AvatarService {
  AvatarService._();

  static const List<String> suggestedSeeds = [
    'Lanvi',
    'Moss',
    'Nova',
    'Atlas',
    'Sage',
    'Echo',
  ];

  static String urlFor(String seed) {
    final encodedSeed = Uri.encodeComponent(seed);
    return 'https://api.dicebear.com/9.x/notionists/png?seed=$encodedSeed';
  }
}
