/// Payload handed to [MockLocationService]. The service still understands speed,
/// bearing, jitter and route, but this build is a static dropper: it parks the fix
/// on one coordinate and holds it there.
class MockRequest {
  const MockRequest({required this.lat, required this.lng, this.intervalMs = 500});

  final double lat;
  final double lng;
  final int intervalMs;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'lat': lat,
        'lng': lng,
        'intervalMs': intervalMs,
        'speed': 0.0,
        'bearing': 0.0,
        'jitter': 0.0,
        'loop': false,
        'routeLat': const <double>[],
        'routeLng': const <double>[],
      };
}
