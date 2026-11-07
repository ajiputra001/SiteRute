import 'package:fake_gps/core/geo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('destination', () {
    test('north by ~111 m moves latitude by ~0.001 deg', () {
      const start = LatLng(0, 0);
      final end = destination(start, 0, 111.32);
      expect(end.latitude, closeTo(0.001, 1e-5));
      expect(end.longitude.abs(), lessThan(1e-9));
    });

    test('east keeps latitude and advances longitude', () {
      const start = LatLng(0, 0);
      final end = destination(start, 90, 1000);
      expect(end.latitude, closeTo(0, 1e-6));
      expect(end.longitude, greaterThan(0));
    });

    test('wraps longitude across the antimeridian', () {
      const start = LatLng(0, 179.999);
      final end = destination(start, 90, 1000);
      expect(end.longitude, closeTo(-179.99, 0.01));
    });
  });

  group('bearing', () {
    test('due east is 90', () {
      expect(
        bearingDegrees(const LatLng(0, 0), const LatLng(0, 1)),
        closeTo(90, 0.5),
      );
    });

    test('due south is 180', () {
      expect(
        bearingDegrees(const LatLng(1, 0), const LatLng(0, 0)),
        closeTo(180, 0.5),
      );
    });
  });

  test('distance and path length agree', () {
    const a = LatLng(-6.175392, 106.827153);
    const b = LatLng(-6.194441, 106.822780);
    final straight = distanceMeters(a, b);
    expect(straight, greaterThan(2000));
    expect(straight, lessThan(2500));
    expect(pathLength([a, b]), closeTo(straight, 0.001));
    expect(pathLength([a, a]), 0);
  });

  test('compass labels map to octants', () {
    expect(compassLabel(0), 'N');
    expect(compassLabel(90), 'E');
    expect(compassLabel(181), 'S');
    expect(compassLabel(359), 'N');
  });

  // The map compass decides "is the map rotated" from this value alone, so the cases
  // that matter are the wrap-arounds: a long twist produces raw angles like 350° or
  // -370°, and without normalisation the button would show for a map that is
  // effectively north-up.
  group('normalizeRotation', () {
    test('leaves values already in range untouched', () {
      expect(normalizeRotation(0), 0);
      expect(normalizeRotation(35), 35);
      expect(normalizeRotation(-35), -35);
      expect(normalizeRotation(180), 180);
    });

    test('wraps past a full turn', () {
      expect(normalizeRotation(350), closeTo(-10, 1e-9));
      expect(normalizeRotation(370), closeTo(10, 1e-9));
      expect(normalizeRotation(720), 0);
      // -370° is one full turn clockwise past -10°, so it folds back to -10°, not +10°.
      // Getting the sign wrong here would make the compass claim "east of north" for a
      // map rotated ten degrees west.
      expect(normalizeRotation(-370), closeTo(-10, 1e-9));
      expect(normalizeRotation(181), closeTo(-179, 1e-9));
    });

    test('snaps sub-degree noise flat so the button does not linger', () {
      expect(normalizeRotation(0.4), 0);
      expect(normalizeRotation(-0.4), 0);
      expect(normalizeRotation(359.7), 0);
      // Just past the threshold must survive, otherwise the compass can never appear.
      expect(normalizeRotation(0.6), closeTo(0.6, 1e-9));
    });

    test('never returns a value the compass would read as rotated', () {
      for (var raw = -2000.0; raw <= 2000.0; raw += 7.5) {
        final n = normalizeRotation(raw);
        expect(n, greaterThanOrEqualTo(-180));
        expect(n, lessThanOrEqualTo(180));
        // Anything snapped to zero must be inside the dead zone.
        if (n == 0) expect(normalizeRotation(raw).abs(), lessThan(0.5));
      }
    });
  });
}
