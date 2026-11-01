import 'package:fake_gps/models/map_source.dart';
import 'package:fake_gps/models/mock_request.dart';
import 'package:fake_gps/models/spot.dart';
import 'package:fake_gps/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('MapSource', () {
    test('every source declares a template, attribution and zoom cap', () {
      for (final source in MapSource.values) {
        expect(source.urlTemplate, contains('{z}'));
        expect(source.urlTemplate, contains('{x}'));
        expect(source.urlTemplate, contains('{y}'));
        expect(source.attribution.isNotEmpty, isTrue);
        expect(source.maxZoom, greaterThanOrEqualTo(18));
      }
    });

    test('unknown id falls back to Google Road', () {
      expect(MapSource.fromId('nope'), MapSource.googleRoad);
      expect(MapSource.fromId(null), MapSource.googleRoad);
      expect(MapSource.fromId('google_road'), MapSource.googleRoad);
      expect(MapSource.fromId('osm'), MapSource.osm);
    });
  });

  group('MockRequest', () {
    test('is a static dropper: no speed, bearing, jitter or route', () {
      const request = MockRequest(lat: -6.2, lng: 106.8);
      final map = request.toMap();

      expect(map['lat'], -6.2);
      expect(map['lng'], 106.8);
      expect(map['intervalMs'], 500);
      expect(map['speed'], 0.0);
      expect(map['bearing'], 0.0);
      expect(map['jitter'], 0.0);
      expect(map['loop'], false);
      expect(map['routeLat'], isEmpty);
      expect(map['routeLng'], isEmpty);
    });
  });

  test('AppSettings defaults are sane', () {
    const settings = AppSettings();
    expect(settings.source, MapSource.googleRoad);
    expect(settings.follow, isTrue);
    expect(settings.target.latitude, closeTo(-6.175, 0.01));
  });

  test('Spot round-trips through json', () {
    final spot = Spot.at(const LatLng(-6.1, 106.9), 'Titik uji');
    final again = Spot.fromJson(spot.toJson());
    expect(again.name, 'Titik uji');
    expect(again.lat, closeTo(-6.1, 1e-9));
    expect(again.lng, closeTo(106.9, 1e-9));
  });
}
