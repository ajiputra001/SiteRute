import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _earthRadius = 6371000.0;

/// Great-circle distance in meters.
double distanceMeters(LatLng a, LatLng b) {
  final dLat = _rad(b.latitude - a.latitude);
  final dLng = _rad(b.longitude - a.longitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(a.latitude)) *
          math.cos(_rad(b.latitude)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * _earthRadius * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

/// Initial bearing a -> b in degrees, 0 = north, clockwise.
double bearingDegrees(LatLng a, LatLng b) {
  final phi1 = _rad(a.latitude);
  final phi2 = _rad(b.latitude);
  final dLng = _rad(b.longitude - a.longitude);
  final y = math.sin(dLng) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLng);
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// Point reached by travelling [meters] from [from] along [bearing] degrees.
LatLng destination(LatLng from, double bearing, double meters) {
  final angular = meters / _earthRadius;
  final brng = _rad(bearing);
  final lat1 = _rad(from.latitude);
  final lng1 = _rad(from.longitude);

  final lat2 = math.asin(math.sin(lat1) * math.cos(angular) +
      math.cos(lat1) * math.sin(angular) * math.cos(brng));
  final lng2 = lng1 +
      math.atan2(math.sin(brng) * math.sin(angular) * math.cos(lat1),
          math.cos(angular) - math.sin(lat1) * math.sin(lat2));

  return LatLng(_deg(lat2), _normalizeLng(_deg(lng2)));
}

/// Total length of a polyline in meters.
double pathLength(List<LatLng> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += distanceMeters(points[i - 1], points[i]);
  }
  return total;
}

/// Camera rotation normalised to -180…180, with near-north snapped to exactly zero.
///
/// A twist gesture accumulates rotation without bound, so the raw camera value can read
/// 350°, -370° or 720°. The compass needs one canonical form — "how far from north, and
/// which way" — because visibility is tested as `abs() > 0.5`. Half a degree below zero
/// is gesture rounding, not a rotation an operator would want to undo, so it snaps flat
/// and the reset button disappears instead of lingering at 0.3°.
///
/// Distinct from `latlong2`'s `normalizeBearing`, which is imported through
/// `package:latlong2/latlong.dart` and returns 0…360 for a compass bearing. This one
/// keeps the sign (west of north is negative) and applies the dead zone; swapping them
/// would make every western rotation read as +350 and keep the button up forever.
double normalizeRotation(double degrees) {
  var v = degrees % 360.0;
  if (v > 180.0) v -= 360.0;
  if (v < -180.0) v += 360.0;
  if (v.abs() < 0.5) return 0.0;
  return v;
}

String fmtCoord(double value) => value.toStringAsFixed(6);

String fmtDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

String fmtSpeed(double mps) {
  if (mps <= 0) return '0 m/s';
  return '${mps.toStringAsFixed(1)} m/s · ${(mps * 3.6).round()} km/h';
}

String compassLabel(double bearing) {
  const labels = [
    'N',
    'NNE',
    'NE',
    'ENE',
    'E',
    'ESE',
    'SE',
    'SSE',
    'S',
    'SSW',
    'SW',
    'WSW',
    'W',
    'WNW',
    'NW',
    'NNW',
  ];
  final index = (((bearing % 360) + 360) % 360 / 22.5).round() % 16;
  return labels[index];
}

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

double _normalizeLng(double lng) {
  var v = lng;
  while (v > 180) {
    v -= 360;
  }
  while (v < -180) {
    v += 360;
  }
  return v;
}
