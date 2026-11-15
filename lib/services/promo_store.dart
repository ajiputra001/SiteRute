import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which promo the operator closed, and when.
///
/// Two keys, not one: the **id** keeps a closed campaign closed, and the **timestamp**
/// lets it come back after a cooldown. A plain boolean would silence every future promo
/// forever; an id alone would silence it permanently too, which is the behaviour this
/// replaced.
///
/// The id is still required because a campaign change must show up immediately rather
/// than waiting out the remaining cooldown.
class PromoStore {
  static const String _kDismissedId = 'promo.dismissedId';
  static const String _kDismissedAt = 'promo.dismissedAt';

  /// The dismissal record.
  ///
  /// [at] is null when the id was stored by an older build that had no timestamp; callers
  /// treat that as "age unknown" and show the promo, which is the safe direction — better
  /// to show a campaign than to hide it forever because of a stale key.
  static Future<({String? id, DateTime? at})> dismissal() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kDismissedId);
    final ms = prefs.getInt(_kDismissedAt);
    return (
      id: id,
      at: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  static Future<void> dismiss(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDismissedId, id);
    await prefs.setInt(_kDismissedAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Clears the dismissal — used when the operator opens the promo again.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDismissedId);
    await prefs.remove(_kDismissedAt);
  }
}
