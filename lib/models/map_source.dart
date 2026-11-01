import 'package:flutter/material.dart';

/// Tile endpoints the app can switch between at runtime.
///
/// `google*` read Google's public raster tile endpoints directly (no key, no SDK).
/// They are the closest thing to "the Google Maps look" without a Maps SDK key —
/// and, like any unofficial endpoint, they can change without notice.
enum MapSource {
  osm(
    id: 'osm',
    label: 'OSM',
    description: 'OpenStreetMap standar — paling lengkap untuk data jalan.',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    maxZoom: 19,
    dark: false,
  ),
  googleRoad(
    id: 'google_road',
    label: 'Google',
    description:
        'Tile Google Maps jalan — tampilan paling mirip aplikasi Google Maps.',
    urlTemplate: 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}',
    subdomains: <String>['0', '1', '2', '3'],
    attribution: '© Google',
    maxZoom: 20,
    dark: false,
  ),
  googleSat(
    id: 'google_sat',
    label: 'Satelit',
    description: 'Citra satelit Google, label jalan di atasnya.',
    urlTemplate: 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}',
    subdomains: <String>['0', '1', '2', '3'],
    attribution: '© Google',
    maxZoom: 20,
    dark: true,
  ),
  esriStreet(
    id: 'esri_street',
    label: 'Esri',
    description: 'Esri World Street Map — gaya kartografi klasik.',
    urlTemplate:
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
    attribution: '© Esri, HERE, Garmin, OpenStreetMap',
    maxZoom: 19,
    dark: false,
  ),
  esriSat(
    id: 'esri_sat',
    label: 'Esri Sat',
    description: 'Esri World Imagery — satelit resolusi tinggi.',
    urlTemplate:
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    attribution: '© Esri, Maxar, Earthstar Geographics',
    maxZoom: 19,
    dark: true,
  );

  const MapSource({
    required this.id,
    required this.label,
    required this.description,
    required this.urlTemplate,
    required this.attribution,
    required this.maxZoom,
    required this.dark,
    this.subdomains = const <String>['a', 'b', 'c'],
  });

  final String id;
  final String label;
  final String description;
  final String urlTemplate;
  final String attribution;
  final int maxZoom;
  final bool dark;
  final List<String> subdomains;

  static MapSource fromId(String? id) => MapSource.values.firstWhere(
        (source) => source.id == id,
        orElse: () => MapSource.googleRoad,
      );

  /// When a third-party tile host drops a request, fill the gap with OSM instead of
  /// leaving a hole in the map.
  String? get fallbackUrl =>
      this == MapSource.osm ? null : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Light/dark label colours that stay readable over each basemap.
  Color labelColor(BuildContext context) =>
      dark ? Colors.white : Colors.black87;
}
