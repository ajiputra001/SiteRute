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
}
