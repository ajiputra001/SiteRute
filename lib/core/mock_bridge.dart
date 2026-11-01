import 'dart:io';

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../models/mock_request.dart';

/// One row of the provider matrix: is this fake source attached, and is it landing?
class ProviderHealth {
  const ProviderHealth({
    required this.name,
    this.attached = false,
    this.enabled = false,
    this.pushes = 0,
    this.failures = 0,
    this.error,
  });

  final String name;
  final bool attached;
  final bool enabled;
  final int pushes;
  final int failures;
  final String? error;

  factory ProviderHealth.fromMap(Map<Object?, Object?> map) => ProviderHealth(
        name: map['name']?.toString() ?? '?',
        attached: map['attached'] as bool? ?? false,
        enabled: map['enabled'] as bool? ?? false,
        pushes: (map['pushes'] as num?)?.toInt() ?? 0,
        failures: (map['failures'] as num?)?.toInt() ?? 0,
        error: map['error'] as String?,
      );
}

/// One row of a live probe: what the provider reports right now vs. the mock target.
class ProbeRow {
  const ProbeRow({
    required this.name,
    required this.match,
    required this.source,
    required this.note,
    this.distance,
  });

  final String name;
  final bool match;
  final String source;
  final String note;
  final double? distance;

  factory ProbeRow.fromMap(Map<Object?, Object?> map) => ProbeRow(
        name: map['name']?.toString() ?? '?',
        match: map['match'] as bool? ?? false,
        source: map['source']?.toString() ?? '?',
        note: map['note']?.toString() ?? '',
        distance: (map['distance'] as num?)?.toDouble(),
      );
}

class ProbeResult {
  const ProbeResult({
    required this.running,
    required this.target,
    required this.rows,
  });

  final bool running;
  final LatLng? target;
  final List<ProbeRow> rows;

  static const ProbeResult empty =
      ProbeResult(running: false, target: null, rows: <ProbeRow>[]);

  factory ProbeResult.fromMap(Map<Object?, Object?> map) {
    final target = map['target'];
    LatLng? point;
    if (target is Map) {
      final lat = (target['lat'] as num?)?.toDouble();
      final lng = (target['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) point = LatLng(lat, lng);
    }
    final rows = (map['rows'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(ProbeRow.fromMap)
        .toList(growable: false);
    return ProbeResult(
      running: map['running'] as bool? ?? false,
      target: point,
      rows: rows,
    );
  }
}

/// A snapshot of what the Android service is doing right now.
class MockStatus {
  const MockStatus({
    this.running = false,
    this.lat = 0,
    this.lng = 0,
    this.speed = 0,
    this.bearing = 0,
    this.intervalMs = 500,
    this.tickCount = 0,
    this.uptimeMs = 0,
    this.providers = const <String>[],
    this.health = const <ProviderHealth>[],
    this.error,
    this.mockSelected = false,
    this.batteryUnrestricted = false,
    this.locationGranted = false,
    this.lastTickAt = 0,
    this.stale = false,
    this.exactAlarmGranted = false,
  });

  final bool running;
  final double lat;
  final double lng;
  final double speed;
  final double bearing;
  final int intervalMs;
  final int tickCount;
  final int uptimeMs;
  final List<String> providers;
  final List<ProviderHealth> health;
  final String? error;
  final bool mockSelected;
  final bool batteryUnrestricted;
  final bool locationGranted;
  /// Wall-clock ms of the last tick the service delivered.
  final int lastTickAt;
  /// True when the service claims to run but has not ticked recently.
  final bool stale;

  /// Whether the OS allows exact alarms. Required for the anti-freeze watchdog.
  final bool exactAlarmGranted;

  static const MockStatus idle = MockStatus();

  Duration get tickRate => Duration(milliseconds: intervalMs);
  Duration get uptime => Duration(milliseconds: uptimeMs);

  factory MockStatus.fromMap(Map<Object?, Object?> map) => MockStatus(
        running: map['running'] as bool? ?? false,
        lat: (map['lat'] as num?)?.toDouble() ?? 0,
        lng: (map['lng'] as num?)?.toDouble() ?? 0,
        speed: (map['speed'] as num?)?.toDouble() ?? 0,
        bearing: (map['bearing'] as num?)?.toDouble() ?? 0,
        intervalMs: (map['intervalMs'] as num?)?.toInt() ?? 500,
        tickCount: (map['tickCount'] as num?)?.toInt() ?? 0,
        uptimeMs: (map['uptimeMs'] as num?)?.toInt() ?? 0,
        providers: (map['providers'] as List<Object?>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        health: (map['health'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(ProviderHealth.fromMap)
            .toList(growable: false),
        error: map['error'] as String?,
        mockSelected: map['mockSelected'] as bool? ?? false,
        batteryUnrestricted: map['batteryUnrestricted'] as bool? ?? false,
        locationGranted: map['locationGranted'] as bool? ?? false,
        lastTickAt: (map['lastTickAt'] as num?)?.toInt() ?? 0,
        stale: map['stale'] as bool? ?? false,
        exactAlarmGranted: map['exactAlarmGranted'] as bool? ?? false,
      );
}

/// Thin typed wrapper over `com.ajiputra.fake_gps/control`.
///
/// Every call is guarded: on a non-Android host the bridge degrades to no-ops so
/// the widget tree still renders (useful for `flutter run -d linux` and tests).
class MockBridge {
  static const MethodChannel _channel =
      MethodChannel('com.ajiputra.fake_gps/control');

  static bool get isSupported {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<MockStatus> status() async {
    final raw = await _invoke<Map<Object?, Object?>>('status');
    if (raw == null) return MockStatus.idle;
    return MockStatus.fromMap(raw);
  }

  /// Asks the platform what each provider currently reports — the honest check.
  ///
  /// Deliberately unused by the UI: the diagnostics sheet was removed on request, and
  /// the in-app probe row went with it. Kept as a live bridge because the native handler
  /// is still the fastest way to confirm "is this provider actually reporting my
  /// coordinate" from a Dart console or a future build without re-adding UI. If that
  /// stops being true, delete this method *and* the `"probe"` case in MainActivity
  /// together — leaving one half is how a channel silently drifts out of sync.
  static Future<ProbeResult> probe() async {
    final raw = await _invoke<Map<Object?, Object?>>('probe');
    if (raw == null) return ProbeResult.empty;
    return ProbeResult.fromMap(raw);
  }

  static Future<bool> isMockAppSelected() async =>
      await _invoke<bool>('isMockAppSelected') ?? false;

  /// Re-reads the cached permission gates natively. Grep for `refreshGates` in
  /// MainActivity: it is the only way to make a `status()` call reflect a setting the
  /// user just changed in the system UI.
  static Future<void> refreshGates() async {
    await _invoke<bool>('refreshGates');
  }

  static Future<bool> hasLocationPermission() async =>
      await _invoke<bool>('hasLocationPermission') ?? false;

  /// Asks for location + notification permission in one shot.
  static Future<bool> requestPermissions() async =>
      await _invoke<bool>('requestPermissions') ?? false;

  static Future<bool> openDeveloperSettings() async =>
      await _invoke<bool>('openDeveloperSettings') ?? false;

  static Future<bool> openBatterySettings() async =>
      await _invoke<bool>('openBatterySettings') ?? false;

  /// Opens the "allow exact alarms" screen. Used when the watchdog fell back to an
  /// inexact alarm, which does not survive a ColorOS process freeze.
  static Future<bool> openExactAlarmSettings() async =>
      await _invoke<bool>('openExactAlarmSettings') ?? false;

  /// Reads the device's real position once. Throws [PlatformException] with code
  /// `NO_FIX` when nothing arrives within 10 s.
  static Future<LatLng?> realLocation() async {
    final raw = await _invoke<Map<Object?, Object?>>('realLocation');
    if (raw == null) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  /// Throws [PlatformException] with code `MOCK_NOT_ALLOWED` when the package is
  /// not the selected mock location app, or `PERMISSION_DENIED`.
  static Future<void> start(MockRequest request) async {
    await _invoke<bool>('start', request.toMap());
  }

  static Future<void> update({
    double? lat,
    double? lng,
    double? speed,
    double? bearing,
    int? intervalMs,
    double? jitter,
    bool? loop,
    List<dynamic>? routeLat,
    List<dynamic>? routeLng,
  }) async {
    await _invoke<void>('update', <String, dynamic>{
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (speed != null) 'speed': speed,
      if (bearing != null) 'bearing': bearing,
      if (intervalMs != null) 'intervalMs': intervalMs,
      if (jitter != null) 'jitter': jitter,
      if (loop != null) 'loop': loop,
      if (routeLat != null) 'routeLat': routeLat,
      if (routeLng != null) 'routeLng': routeLng,
    });
  }

  static Future<void> stop() async => _invoke<void>('stop');
}
