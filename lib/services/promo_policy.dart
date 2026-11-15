/// When a closed promo is allowed to come back.
///
/// Kept as pure functions, away from the widget, because the boundary is the part that
/// silently breaks: an off-by-one at the cooldown edge either hides the card forever or
/// pops it back the moment it is closed.
library;

/// True when the card should be shown again.
///
/// A different campaign always returns immediately — the operator changed the offer, so
/// the old dismissal no longer applies.
bool promoDueToReturn({
  required DateTime now,
  required DateTime? dismissedAt,
  required bool sameCampaign,
  required Duration cooldown,
}) {
  if (!sameCampaign) return true;
  // Dismissed by a build that stored no timestamp: age is unknown, so show it. Hiding
  // would let one stale key silence every future card.
  if (dismissedAt == null) return true;
  return now.difference(dismissedAt) >= cooldown;
}

/// How long until the card returns, or null when it is already due (or never dismissed).
///
/// Drives the timer that re-shows the card while the app is open, so the operator does
/// not have to relaunch for a cooldown that expired mid-session.
Duration? promoReappearIn({
  required DateTime now,
  required DateTime? dismissedAt,
  required bool sameCampaign,
  required Duration cooldown,
}) {
  if (!sameCampaign || dismissedAt == null) return null;
  final elapsed = now.difference(dismissedAt);
  if (elapsed >= cooldown) return null;
  return cooldown - elapsed;
}
