import 'package:latlong2/latlong.dart';

/// A saved coordinate with a human label.
class Spot {
  const Spot({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;

  LatLng get point => LatLng(lat, lng);

  Spot copyWith({String? name, double? lat, double? lng}) => Spot(
        id: id,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
      };

  static Spot fromJson(Map<String, dynamic> json) => Spot(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? 'Tanpa nama',
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0,
      );

  static Spot at(LatLng point, String name) => Spot(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        lat: point.latitude,
        lng: point.longitude,
      );
}
