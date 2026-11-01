import 'dart:async';

import 'package:flutter/material.dart';

import '../core/mock_bridge.dart';

/// Live diagnosis: which gates are open, which providers are attached, and whether
/// a read-back of the platform providers actually returns the mock coordinate.
Future<void> showDiagnosticsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _DiagnosticsSheet(),
  );
}

class _DiagnosticsSheet extends StatefulWidget {
  const _DiagnosticsSheet();

  @override
  State<_DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends State<_DiagnosticsSheet> {
  MockStatus? _status;
  ProbeResult? _probe;
  bool _probing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await MockBridge.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _runProbe() async {
    setState(() => _probing = true);
    final result = await MockBridge.probe();
    if (!mounted) return;
    setState(() {
      _probe = result;
      _probing = false;
    });
  }

  String _uptime(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} dtk';
    final minutes = d.inMinutes.remainder(60);
    final hours = d.inHours;
    if (hours == 0) return '$minutes mnt';
    return '$hours j $minutes mnt';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status ?? MockStatus.idle;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                Text('Diagnosa', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Segarkan',
                ),
              ],
            ),
            _gateTile(
              context,
              ok: status.mockSelected,
              title: 'Aplikasi lokasi tiruan',
              detail: status.mockSelected
                  ? 'Terpilih di Opsi pengembang'
                  : 'Belum dipilih — Android akan menolak semua test provider',
              actionLabel: status.mockSelected ? null : 'Atur',
              onAction: () => MockBridge.openDeveloperSettings(),
            ),
            _gateTile(
              context,
              ok: status.locationGranted,
              title: 'Izin lokasi',
              detail: status.locationGranted ? 'Diberikan' : 'Ditolak',
              actionLabel: status.locationGranted ? null : 'Minta',
              onAction: () => MockBridge.requestPermissions(),
            ),
            _gateTile(
              context,
              ok: status.batteryUnrestricted,
              title: 'Optimasi baterai',
              detail: status.batteryUnrestricted
                  ? 'Dikecualikan — service tidak dibekukan'
                  : 'Masih dioptimasi — service bisa dibunuh OS (penyebab posisi balik ke GPS asli)',
              actionLabel: status.batteryUnrestricted ? null : 'Ubah',
              onAction: () => MockBridge.openBatterySettings(),
            ),
            const Divider(height: 24),
            _sectionTitle(context, 'Service'),
            _kv(context, 'Status', status.running ? 'Berjalan' : 'Berhenti'),
            if (status.running) ...[
              _kv(context, 'Uptime', _uptime(status.uptime)),
              _kv(context, 'Tick',
                  '${status.tickCount}× · ${status.intervalMs} ms'),
              _kv(context, 'Koordinat',
                  '${status.lat.toStringAsFixed(6)}, ${status.lng.toStringAsFixed(6)}'),
            ],
            if (status.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  status.error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const Divider(height: 24),
            _sectionTitle(context, 'Provider'),
            if (status.health.isEmpty)
              Text('Belum ada data.', style: theme.textTheme.bodySmall)
            else
              for (final health in status.health) _providerRow(context, health),
            const Divider(height: 24),
            Row(
              children: [
                _sectionTitle(context, 'Uji baca ulang'),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: _probing ? null : _runProbe,
                  icon: _probing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.science_outlined, size: 18),
                  label: const Text('Tes sekarang'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_probe == null)
              Text(
                'Membaca `getLastKnownLocation` tiap provider dan membandingkannya '
                'dengan koordinat mock. Kalau hasilnya "real", berarti ada sumber lain '
                'yang menang di provider itu.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final row in _probe!.rows) _probeRow(context, row),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: theme.textTheme.labelLarge),
    );
  }

  Widget _kv(BuildContext context, String key, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _gateTile(
    BuildContext context, {
    required bool ok,
    required String title,
    required String detail,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(title, style: theme.textTheme.bodyMedium),
      subtitle: Text(detail, style: theme.textTheme.labelSmall),
      trailing: actionLabel == null
          ? null
          : TextButton(onPressed: onAction, child: Text(actionLabel)),
    );
  }

  Widget _providerRow(BuildContext context, ProviderHealth health) {
    final theme = Theme.of(context);
    final ok = health.attached;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.remove_circle_outline,
            size: 16,
            color: ok ? theme.colorScheme.primary : theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              health.name,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              ok
                  ? '${health.pushes} kirim · ${health.failures} gagal'
                  : (health.error ?? 'tidak terpasang'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: ok
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _probeRow(BuildContext context, ProbeRow row) {
    final theme = Theme.of(context);
    final color =
        row.match ? theme.colorScheme.primary : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(row.match ? Icons.check_circle : Icons.cancel_outlined,
              size: 16, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              row.name,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              row.distance == null
                  ? row.note
                  : '${row.source} · ${row.distance!.toStringAsFixed(1)} m dari target',
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
