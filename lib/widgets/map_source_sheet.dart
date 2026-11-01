import 'package:flutter/material.dart';

import '../models/map_source.dart';

/// Bottom sheet that switches the basemap. Returns the chosen source or null.
Future<MapSource?> showMapSourceSheet(BuildContext context, MapSource current) {
  return showModalBottomSheet<MapSource>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Sumber peta', style: theme.textTheme.titleMedium),
              ),
              for (final source in MapSource.values)
                ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: source.dark
                        ? Colors.black87
                        : theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      source.dark ? Icons.satellite_alt : Icons.map_outlined,
                      size: 18,
                      color: source.dark
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: Text(source.label),
                  subtitle: Text(source.description),
                  trailing: source == current
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, source),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  'Google dan Esri di sini memakai endpoint tile publik tanpa API key. '
                  'Kalau salah satu berhenti tampil, ganti ke OSM.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
