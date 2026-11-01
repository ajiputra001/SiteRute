import 'package:flutter/material.dart';

import 'screens/map_screen.dart';

void main() => runApp(const SiteRouteApp());

class SiteRouteApp extends StatelessWidget {
  const SiteRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    // `#14B4CC` is the logo's own teal, sampled from 81 % of its opaque pixels.
    const seed = Color(0xFF14B4CC);

    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF0E1B1E),
      surfaceContainerHighest: const Color(0xFF14262A),
      outlineVariant: const Color(0xFF234046),
      primary: seed,
      tertiary: const Color(0xFF59D6E6),
    );

    return MaterialApp(
      title: 'SiteRoute',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF081014),
        // InkSparkle costs a shader compile per tap on mid-range devices;
        // InkRipple is free and this app has no canvas-heavy UI to lose.
        splashFactory: InkRipple.splashFactory,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          insetPadding: EdgeInsets.all(12),
        ),
      ),
      home: const MapScreen(),
    );
  }
}
