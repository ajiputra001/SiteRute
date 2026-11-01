import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/spot.dart';

/// Nominatim (OpenStreetMap) forward geocoding — keyless, no billing.
///
/// The usage policy is real: about one request per second and a User-Agent that
/// identifies the app. Both are honoured here.
class Geocoder {
  static const String _userAgent = 'TelemetryKit/1.0 (com.ajiputra.telemetrykit)';

  static Future<List<Spot>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return <Spot>[];

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': trimmed,
      'format': 'jsonv2',
      'limit': '6',
      'accept-language': 'id,en',
    });

    final response = await http
        .get(uri, headers: const {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) {
      throw Exception('Nominatim HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return <Spot>[];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map((row) {
          final lat = double.tryParse(row['lat']?.toString() ?? '');
          final lon = double.tryParse(row['lon']?.toString() ?? '');
          if (lat == null || lon == null) return null;
          final name = (row['display_name']?.toString() ?? trimmed).split(',');
          return Spot(
            id: '${row['place_id'] ?? lat}_$lon',
            name: name.take(2).join(', ').trim(),
            lat: lat,
            lng: lon,
          );
        })
        .whereType<Spot>()
        .toList(growable: false);
  }
}
