import 'dart:io';

import 'package:flutter/material.dart';

import '../core/update_bridge.dart';

/// Update prompt, shown as a centred popup card over a dimmed scrim.
///
/// Positioned as a sibling layer inside the screen's own [Stack], never as a wrapper
/// around the app content. Wrapping the `Scaffold` stopped the map's `RepaintBoundary`
/// from compositing under an alpha scrim on this device, so the backdrop painted flat
/// `#081014` instead of a dimmed map. A sibling layer leaves the render tree untouched.
///
/// Back is swallowed by [PopScope] and the scrim absorbs taps, so the only exits are
/// installing or (when the manifest did not force it) dismissing.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    super.key,
    required this.info,
    this.onDismiss,
    this.onInstalled,
  });

  /// The manifest evaluation. `blocked` true means no dismiss control is rendered.
  final UpdateInfo info;

  /// Called when the operator dismisses a non-forced notice. Null on a forced update.
  final VoidCallback? onDismiss;

  /// Called once the platform reports the install actually succeeded. The parent uses it
  /// to drop the popup immediately instead of waiting for the next 15-minute poll.
  final VoidCallback? onInstalled;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

enum _Phase { idle, downloading, ready, installing, failed }

class _UpdateGateState extends State<UpdateGate> {
  _Phase _phase = _Phase.idle;
  String? _error;
  String? _apkPath;

  /// Live label while installing — "Menunggu konfirmasi…" while the OS dialog is up, so
  /// the operator can tell the difference between "working" and "nothing happened".
  String? _stage;
  bool _canInstall = true;

  bool get _forced => widget.info.blocked;

  @override
  void initState() {
    super.initState();
    _probeInstallPermission();
  }

  Future<void> _probeInstallPermission() async {
    final ok = await UpdateBridge.canInstall();
    if (!mounted) return;
    setState(() => _canInstall = ok);
  }

  Future<void> _start() async {
    // A verified APK from a previous attempt is reused. Re-downloading 48 MB because the
    // OS dialog was cancelled is exactly the friction that made this feel broken — the
    // file is already on disk and its digest was checked when it arrived.
    if (_phase == _Phase.failed && _apkPath != null) {
      await _install();
      return;
    }

    // "Install unknown apps" is per-package on API 26+ and cannot be granted through a
    // permission dialog — only through this settings page. Checked before the download
    // so a 48 MB transfer is never wasted on an install that would be refused.
    if (!_canInstall) {
      final opened = await UpdateBridge.openInstallSettings();
      if (!mounted) return;
      if (!opened) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Tidak bisa membuka pengaturan izin pemasangan.';
        });
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final now = await UpdateBridge.canInstall();
      if (!mounted) return;
      setState(() => _canInstall = now);
      if (!now) return;
    }

    setState(() {
      _phase = _Phase.downloading;
      _error = null;
      _stage = null;
    });

    final result = await UpdateBridge.download();
    if (!mounted) return;

    if (!result.ok || result.path == null) {
      setState(() {
        _phase = _Phase.failed;
        _error = result.error ?? 'Unduhan gagal.';
      });
      return;
    }

    setState(() {
      _phase = _Phase.ready;
      _apkPath = result.path;
    });
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;

    setState(() {
      _phase = _Phase.installing;
      _error = null;
      _stage = 'Membuka pemasang…';
    });

    final started = await UpdateBridge.install(path);
    if (!mounted) return;
    if (!started.ok) {
      setState(() {
        _phase = _Phase.failed;
        _error = started.error ?? 'Pemasang tidak bisa dibuka.';
      });
      return;
    }

    // The platform owns the flow from here: it shows its own confirmation, and the answer
    // arrives asynchronously. Assuming success here is what made a refused install look
    // like a dead button, so the verdict is polled instead.
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    var announcedWait = false;

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;

      final snap = await UpdateBridge.installStatus();
      if (!mounted) return;

      if (snap.status == InstallStatus.success) {
        setState(() => _stage = 'Terpasang…');
        widget.onInstalled?.call();
        return;
      }

      if (snap.status == InstallStatus.pendingUserAction) {
        // Normal: the OS is waiting for a tap on its own dialog. Keep waiting.
        if (!announcedWait) {
          announcedWait = true;
          setState(() => _stage = 'Menunggu konfirmasi…');
        }
        continue;
      }

      if (snap.status >= InstallStatus.failure) {
        setState(() {
          _phase = _Phase.failed;
          _error = snap.message ?? 'Pemasangan gagal.';
        });
        return;
      }
      // InstallStatus.none — session committed, broadcast not delivered yet. Keep waiting.
    }

    if (!mounted) return;
    setState(() {
      _phase = _Phase.ready;
      _error = 'Pemasangan belum selesai. Ketuk "Pasang sekarang" untuk mencoba lagi '
          '— berkasnya sudah terunduh.';
    });
  }

  /// The popup card, positioned by the caller as a sibling of the app content rather
  /// than a wrapper around it.
  ///
  /// Wrapping the whole `Scaffold` in this widget — the obvious shape — broke rendering
  /// on this device: the map's `RepaintBoundary` stopped compositing under an alpha
  /// scrim and the backdrop painted as flat `#081014`. Keeping the dimmer as a sibling
  /// layer inside the screen's own `Stack` leaves the existing render tree untouched, so
  /// the map keeps drawing and simply gets dimmed.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = widget.info;

    return PopScope(
      // The gate is a Stack layer, not a route, so an actual pop would exit the activity
      // rather than close this card. Always block the system pop, then route the intent:
      // a soft notice dismisses, a forced update refuses.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!_forced && _phase != _Phase.downloading) widget.onDismiss?.call();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              // Tapping the scrim dismisses only a soft notice; a forced update ignores
              // it. This is the whole difference between "there is an update" and "you
              // cannot continue until you take it".
              onTap: _forced ? null : widget.onDismiss,
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(
                color: const Color(0x9E000000),
                child: Align(
                  alignment: Alignment.center,
                  child: Padding(
                    // Generous inset so the card never touches a screen edge, and sits
                    // clear of the status bar on tall devices.
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 40),
                    child: GestureDetector(
                      // Swallow taps on the card itself so the scrim handler does not fire.
                      onTap: () {},
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: _card(context, scheme, info),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, ColorScheme scheme, UpdateInfo info) {
    return Material(
      color: scheme.surface,
      elevation: 24,
      shadowColor: Colors.black.withOpacity(0.6),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _mark(scheme),
            const SizedBox(height: 18),
            Text(
              _forced ? 'Pembaruan wajib' : 'Pembaruan tersedia',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _forced
                  ? 'Versi ${info.installedName} sudah tidak didukung. '
                      'Pasang versi ${info.latestName ?? ''} untuk melanjutkan.'
                  : 'Versi ${info.latestName ?? ''} sudah tersedia. '
                      'Versi terpasang ${info.installedName}.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withOpacity(0.7),
                    height: 1.5,
                  ),
            ),
            if ((info.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withOpacity(0.35),
                  ),
                ),
                child: Text(
                  info.notes!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withOpacity(0.78),
                        height: 1.5,
                      ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            _action(context, scheme),
            if (_phase == _Phase.ready || _phase == _Phase.installing) ...[
              const SizedBox(height: 10),
              // The OS shows its own confirmation screen, and Play Protect may scan the
              // APK before it installs. Saying so up front is what stops the operator
              // from backing out of that dialog and reporting "the button does nothing".
              Text(
                'Konfirmasi pemasangan muncul dari sistem. Jika Google Play Protect '
                'tampil, pilih "Instal".',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurface.withOpacity(0.45),
                      height: 1.4,
                    ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                      height: 1.4,
                    ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Terpasang ${info.installedName} · terbaru ${info.latestName ?? '?'}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface.withOpacity(0.38),
                  ),
            ),
            if (!_forced) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () {
                  if (_phase == _Phase.downloading) return;
                  widget.onDismiss?.call();
                },
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurface.withOpacity(0.55),
                  minimumSize: const Size.fromHeight(42),
                ),
                child: const Text('Nanti'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mark(ColorScheme scheme) {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary.withOpacity(0.12),
          border: Border.all(color: scheme.primary.withOpacity(0.32)),
        ),
        alignment: Alignment.center,
        child: Icon(
          _phase == _Phase.failed
              ? Icons.sync_problem_rounded
              : _phase == _Phase.ready || _phase == _Phase.installing
                  ? Icons.system_update_alt_rounded
                  : Icons.system_update_rounded,
          color: _phase == _Phase.failed ? scheme.error : scheme.primary,
          size: 30,
        ),
      ),
    );
  }

  Widget _action(BuildContext context, ColorScheme scheme) {
    final busy = _phase == _Phase.downloading || _phase == _Phase.installing;
    final label = switch (_phase) {
      _Phase.idle => _canInstall ? 'Unduh pembaruan' : 'Izinkan pemasangan',
      _Phase.downloading => 'Mengunduh…',
      _Phase.ready => 'Pasang sekarang',
      _Phase.installing => _stage ?? 'Membuka pemasang…',
      _Phase.failed => 'Coba lagi',
    };

    return SizedBox(
      height: 50,
      child: FilledButton(
        onPressed: busy
            ? null
            : (_phase == _Phase.ready || _phase == _Phase.installing)
                ? _install
                : _start,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.primary.withOpacity(0.35),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        child: busy
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Text(label),
                ],
              )
            : Text(label),
      ),
    );
  }
}

/// Quietly reports whether this build is running on Android. Kept out of the widget so
/// the gate itself compiles on any platform while the updater stays Android-only.
bool get updatesSupported => Platform.isAndroid;
