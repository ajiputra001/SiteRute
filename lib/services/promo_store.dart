import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which promo the operator closed.
///
/// Stored as the promo **id**, not a boolean. That way a new campaign — a different id in
/// the manifest — shows up again for everyone, while the one they closed stays closed.
/// A boolean would silence every future promo forever after the first dismiss.
class PromoStore {
  static const String _kDismissedId = 'promo.dismissedId';

  static Future<String?> dismissedId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDismissedId);
  }

  static Future<void> dismiss(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDismissedId, id);
  }

  /// Clears the dismissal — used when the operator opens the promo again from the sheet.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDismissedId);
  }
}
