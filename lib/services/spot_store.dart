import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/spot.dart';

/// Saved points, persisted as one JSON blob.
///
/// The list starts empty by design — there are no demo entries. Earlier builds
/// seeded two points ("Monas", "Bundaran HI"); [_stripLegacySeeds] removes them once
/// on upgrade so an existing install is not left with entries the operator never
/// created.
class SpotStore {
  static const String _key = 'spots.v1';
  static const String _kSeedsRemoved = 'spots.seedsRemoved';

  /// The exact seeded pair from the older build, matched by name *and* coordinate so
  /// a real point the operator saved at Monas is never deleted.
  static const List<({String name, double lat, double lng})> _legacySeeds = [
    (name: 'Monas', lat: -6.175392, lng: 106.827153),
    (name: 'Bundaran HI', lat: -6.194441, lng: 106.822780),
  ];

  static Future<List<Spot>> load() async {
    final prefs = await SharedPreferences.getInstance();
    var spots = _decode(prefs.getString(_key));
    final cleaned = await _stripLegacySeeds(prefs, spots);
    if (cleaned != null) {
      spots = cleaned;
      await save(spots);
    }
    return spots;
  }

  static List<Spot> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Spot>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(Spot.fromJson)
          .toList(growable: true);
    } catch (_) {
      return <Spot>[];
    }
  }

  /// Returns the filtered list on the first run after upgrade, or null when there is
  /// nothing to do (already migrated, or no seeds present).
  static Future<List<Spot>?> _stripLegacySeeds(
    SharedPreferences prefs,
    List<Spot> spots,
  ) async {
    if (prefs.getBool(_kSeedsRemoved) ?? false) return null;
    final filtered = spots.where((spot) {
      final isSeed = _legacySeeds.any((seed) =>
          seed.name == spot.name &&
          (seed.lat - spot.lat).abs() < 1e-6 &&
          (seed.lng - spot.lng).abs() < 1e-6);
      return !isSeed;
    }).toList(growable: true);
    await prefs.setBool(_kSeedsRemoved, true);
    return filtered;
  }

  static Future<void> save(List<Spot> spots) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(spots.map((s) => s.toJson()).toList(growable: false)),
    );
  }
}
