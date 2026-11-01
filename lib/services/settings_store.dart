import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_source.dart';

/// What survives a restart: basemap, last target, camera follow.
class AppSettings {
  const AppSettings({
    this.source = MapSource.googleRoad,
    this.target = const LatLng(-6.175392, 106.827153),
    this.follow = true,
  });

  final MapSource source;
  final LatLng target;
  final bool follow;

  AppSettings copyWith({MapSource? source, LatLng? target, bool? follow}) =>
      AppSettings(
        source: source ?? this.source,
        target: target ?? this.target,
        follow: follow ?? this.follow,
      );

  /// Bumped when a default has to be re-applied to existing installs.
  /// 2 = Google Road becomes the default basemap.
  static const int _version = 2;

  static const String _kVersion = 'prefs.version';
  static const String _kSource = 'map.source';
  static const String _kLat = 'target.lat';
  static const String _kLng = 'target.lng';
  static const String _kFollow = 'ui.follow';

  /// Offered once, at the first successful start. Doze is the dominant reason a fix
  /// stream stops a few minutes in, and the exemption is the only thing the user can
  /// grant that actually prevents it.
  static const String _kBatteryAsked = 'ui.batteryAsked';

  static Future<bool> batteryPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kBatteryAsked) ?? false;
  }

  static Future<void> markBatteryPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBatteryAsked, true);
  }

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_kVersion) ?? 0;
    final migrate = stored < _version;

    return AppSettings(
      source: migrate
          ? MapSource.googleRoad
          : MapSource.fromId(prefs.getString(_kSource)),
      target: LatLng(
        prefs.getDouble(_kLat) ?? -6.175392,
        prefs.getDouble(_kLng) ?? 106.827153,
      ),
      follow: prefs.getBool(_kFollow) ?? true,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kVersion, _version);
    await prefs.setString(_kSource, source.id);
    await prefs.setDouble(_kLat, target.latitude);
    await prefs.setDouble(_kLng, target.longitude);
    await prefs.setBool(_kFollow, follow);
  }
}
