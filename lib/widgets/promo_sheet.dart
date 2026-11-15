import 'package:flutter/material.dart';

import '../core/update_bridge.dart';

/// Detail sheet for a promo. Returns when closed.
///
/// The card in the map screen is the invitation; this is where the full copy lives, so
/// the bottom card can stay compact enough not to crowd the Start button.
Future<void> showPromoSheet(BuildContext context, PromoInfo promo) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final scheme = theme.colorScheme;

      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _Badge(scheme: scheme, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            promo.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            promo.tagline,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _body(context, promo.body),
                const SizedBox(height: 20),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: () => _open(ctx, promo.url),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: Text(promo.cta),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Chat langsung ke admin lewat WhatsApp.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> _open(BuildContext ctx, String url) async {
  final ok = await UpdateBridge.openUrl(url);
  if (ok || !ctx.mounted) return;
  ScaffoldMessenger.of(ctx)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('WhatsApp atau browser tidak bisa dibuka.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// Renders the campaign copy.
///
/// The text is authored for WhatsApp, where `*…*` means bold. Splitting on the marker and
/// alternating weight reproduces that emphasis here instead of printing asterisks the
/// operator never intended anyone to see. An unbalanced marker simply leaves the tail
/// normal — a malformed remote string must not break the sheet.
Widget _body(BuildContext context, String text) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final base = theme.textTheme.bodyMedium!.copyWith(
    height: 1.62,
    color: scheme.onSurface.withOpacity(0.88),
  );
  final strong = base.copyWith(
    fontWeight: FontWeight.w700,
    color: scheme.onSurface,
  );

  final parts = text.split('*');
  final spans = <TextSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isEmpty) continue;
    spans.add(TextSpan(text: parts[i], style: i.isOdd ? strong : base));
  }

  return Text.rich(TextSpan(children: spans));
}

/// The promo's mark: the app's own logo, so the card reads as part of SiteRoute instead
/// of carrying a second, invented brand.
class _Badge extends StatelessWidget {
  const _Badge({required this.scheme, required this.size});

  final ColorScheme scheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.09),
      decoration: BoxDecoration(
        // The logo is drawn for a light plate; on the dark card it needs its own backing
        // or the mark disappears.
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.27),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.3)),
      ),
      child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
    );
  }
}

/// Small shared badge widget so the card row and the sheet render the same mark.
class PromoBadge extends StatelessWidget {
  const PromoBadge({super.key, required this.scheme, this.size = 34});

  final ColorScheme scheme;
  final double size;

  @override
  Widget build(BuildContext context) => _Badge(scheme: scheme, size: size);
}
