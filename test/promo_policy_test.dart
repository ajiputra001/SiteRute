import 'package:flutter_test/flutter_test.dart';

import 'package:fake_gps/services/promo_policy.dart';

void main() {
  const cooldown = Duration(days: 3);
  final dismissed = DateTime(2026, 11, 15, 10, 0, 0);

  group('promoDueToReturn', () {
    test('a new campaign returns immediately, ignoring the old dismissal', () {
      expect(
        promoDueToReturn(
          now: dismissed,
          dismissedAt: dismissed,
          sameCampaign: false,
          cooldown: cooldown,
        ),
        isTrue,
      );
    });

    test('an unknown dismissal age shows the card rather than hiding it forever', () {
      expect(
        promoDueToReturn(
          now: dismissed,
          dismissedAt: null,
          sameCampaign: true,
          cooldown: cooldown,
        ),
        isTrue,
      );
    });

    test('stays hidden until the cooldown has fully elapsed', () {
      bool at(Duration after) => promoDueToReturn(
            now: dismissed.add(after),
            dismissedAt: dismissed,
            sameCampaign: true,
            cooldown: cooldown,
          );

      expect(at(Duration.zero), isFalse);
      expect(at(const Duration(days: 1)), isFalse);
      expect(at(const Duration(days: 2, hours: 23, minutes: 59)), isFalse);
      // The boundary itself counts as due — closing then immediately re-opening the
      // app must not leave the card hidden for one extra tick.
      expect(at(const Duration(days: 3)), isTrue);
      expect(at(const Duration(days: 3, seconds: 1)), isTrue);
    });
  });

  group('promoReappearIn', () {
    test('reports the remaining time, then null once due', () {
      expect(
        promoReappearIn(
          now: dismissed,
          dismissedAt: dismissed,
          sameCampaign: true,
          cooldown: cooldown,
        ),
        cooldown,
      );

      expect(
        promoReappearIn(
          now: dismissed.add(const Duration(days: 2)),
          dismissedAt: dismissed,
          sameCampaign: true,
          cooldown: cooldown,
        ),
        const Duration(days: 1),
      );

      expect(
        promoReappearIn(
          now: dismissed.add(const Duration(days: 4)),
          dismissedAt: dismissed,
          sameCampaign: true,
          cooldown: cooldown,
        ),
        isNull,
      );
    });

    test('no timer is scheduled for a new campaign or an unknown age', () {
      for (final same in [false]) {
        expect(
          promoReappearIn(
            now: dismissed,
            dismissedAt: dismissed,
            sameCampaign: same,
            cooldown: cooldown,
          ),
          isNull,
        );
      }
      expect(
        promoReappearIn(
          now: dismissed,
          dismissedAt: null,
          sameCampaign: true,
          cooldown: cooldown,
        ),
        isNull,
      );
    });
  });
}
