import 'package:flutter/material.dart';

/// First-frame splash, shown while [MapScreen] loads prefs, spots and status.
///
/// The native launch window (`res/drawable/launch_background.xml`) already paints the
/// same near-black backdrop with the same centred mark, so this widget must start from
/// exactly that composition and only *add* motion — any layout difference shows up as a
/// visible jump at handoff.
///
/// Duration is deliberately short: it fades out as soon as the parent reports loaded,
/// not on a fixed timer, so it never makes startup feel slower than it is.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({
    super.key,
    required this.visible,
    this.onDismissed,
  });

  /// When this flips to false the overlay fades out and calls [onDismissed].
  final bool visible;
  final VoidCallback? onDismissed;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _glow;
  late final Animation<double> _textIn;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    // Mark rises from 0.82 to 1.0 with a soft overshoot. A hard scale-in reads as a
    // loading spinner; the overshoot reads as a logo settling.
    _scale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
      ),
    );
    _glow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
      ),
    );
    // Name and tagline arrive after the mark has landed — staggered, bottom-up.
    _textIn = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant SplashOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible && !widget.visible) {
      _controller.reverse().whenComplete(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final teal = theme.colorScheme.primary;

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: ColoredBox(
              color: const Color(0xFF081014),
              child: Stack(
                children: [
                  // Radial teal wash — same colour and radius as the native drawable's
                  // gradient, so the handoff does not shift.
                  Positioned.fill(
                    child: Center(
                      child: Container(
                        width: 380,
                        height: 380,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            radius: 0.5,
                            colors: [
                              teal.withOpacity(0.20 * _glow.value),
                              teal.withOpacity(0.06 * _glow.value),
                              const Color(0x00081014),
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: _scale.value,
                          child: Opacity(
                            opacity: _glow.value.clamp(0.0, 1.0),
                            child: SizedBox(
                              width: 108,
                              height: 108,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: Image.asset(
                                  'assets/images/logo.png',
                                  fit: BoxFit.cover,
                                  // The native splash shows the launcher mark; this is
                                  // the full logo. They share the same silhouette, so a
                                  // short cross-fade at handoff is invisible.
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        // Name + tagline slide up into place.
                        ClipRect(
                          child: Transform.translate(
                            offset: Offset(0, 14 * (1 - _textIn.value)),
                            child: Opacity(
                              opacity: _textIn.value,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'SiteRoute',
                                    style: theme.textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.4,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Powered by Ajiputra-tech',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: teal.withOpacity(0.85),
                                      letterSpacing: 1.6,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // A thin indeterminate line at the bottom edge is the only "busy"
                  // signal: it moves, so the frame never looks frozen, but it does not
                  // demand attention the way a spinner does.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Opacity(
                      opacity: (1 - _controller.value) * 0.9 + 0.1,
                      child: SizedBox(
                        height: 2,
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: Colors.transparent,
                          color: teal.withOpacity(0.55),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
