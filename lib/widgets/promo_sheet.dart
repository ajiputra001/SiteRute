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
                Text(
                  promo.body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.55,
                    color: scheme.onSurface.withOpacity(0.86),
                  ),
                ),
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

/// Monogram stand-in for the promo's own logo: no asset needed, and it reads as a brand
/// mark rather than a generic Material icon.
class _Badge extends StatelessWidget {
  const _Badge({required this.scheme, required this.size});

  final ColorScheme scheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary,
            scheme.primary.withOpacity(0.62),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        'AP',
        style: TextStyle(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: -0.5,
        ),
      ),
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
