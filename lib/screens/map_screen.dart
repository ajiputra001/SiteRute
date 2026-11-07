import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/mock_bridge.dart';
import '../core/update_bridge.dart';
import '../models/map_source.dart';
import '../models/mock_request.dart';
import '../models/spot.dart';
import '../services/geocoder.dart';
import '../services/settings_store.dart';
import '../services/spot_store.dart';
import '../widgets/map_source_sheet.dart';
import '../widgets/splash_overlay.dart';
import '../widgets/update_gate.dart';

/// One screen, one job: pick a coordinate, hold it.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  static const LatLng _fallback = LatLng(-6.175392, 106.827153);
  static const double _zoom = 16;

  final MapController _map = MapController();
  final TextEditingController _searchCtrl = TextEditingController();

  MapSource _source = MapSource.googleRoad;
  LatLng _target = _fallback;
  bool _follow = true;
  bool _running = false;
  bool _mapReady = false;
  bool _loaded = false;
  /// Set once the splash has finished fading; the overlay is then dropped from the tree
  /// entirely so nothing is composited over the map during normal use.
  bool _splashGone = false;
  bool _searching = false;

  MockStatus _status = MockStatus.idle;
  final ValueNotifier<MockStatus> _statusVN = ValueNotifier<MockStatus>(MockStatus.idle);

  /// Live camera bearing in degrees, normalised to -180…180.
  ///
  /// Held in a notifier rather than in `setState` state on purpose: a twist gesture
  /// emits a position change on every frame, and rebuilding this screen each time would
  /// repaint the map — the exact cost the `RepaintBoundary` around it exists to avoid.
  /// Only the compass icon listens.
  final ValueNotifier<double> _bearingVN = ValueNotifier<double>(0.0);
  String? _lastError;
  bool _starting = false;
  DateTime? _startedAt;
  DateTime? _lastWatchdogAt;
  bool _reviving = false;

  List<Spot> _spots = <Spot>[];
  List<Spot> _searchResults = <Spot>[];
  Timer? _poll;

  /// Latest manifest verdict. Null until the first probe returns; a null here reads as
  /// "no update", so a dead network never shows a popup.
  UpdateInfo? _updateInfo;

  /// Whether the popup is on screen. Separate from `_updateInfo` because a soft notice
  /// can be dismissed without losing the knowledge that an update exists — the periodic
  /// poll must not re-show a popup the operator already closed.
  bool _updateVisible = false;

  /// Tracks the last dismissed version so a dismissed soft notice stays dismissed.
  int? _dismissedCode;

  /// Background re-check cadence. A forced notice must appear even when the app has been
  /// open since before the release was published, so a cold-start-only check is not
  /// enough — the driver may leave this open for a whole shift.
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
    // Not awaited: the popup appears whenever the probe lands, and a slow or dead network
    // must never delay the map. `_updateInfo` stays null until the reply arrives, which
    // the build method reads as "no update to show".
    _checkUpdate();
    // Re-probe every 15 minutes while the app is open. The manifest itself is cached
    // natively for 10 minutes, so this is at most a tiny JSON fetch per quarter hour.
    _updateTimer =
        Timer.periodic(const Duration(minutes: 15), (_) => _checkUpdate());
  }

  /// The operator just came back from Developer options, the battery screen, or the
  /// update installer. Re-read both gates once.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
      // Also re-probe: an update may have been published while the app was backgrounded,
      // and the operator may have just come back from granting "Install unknown apps".
      _checkUpdate();
    }
  }

  /// Exact artifact: the manifest verdict, turned into popup state.
  ///
  /// Three outcomes, and the difference between them matters:
  ///  * forced  — show unconditionally, no way to dismiss, re-shown on every probe.
  ///  * soft    — show once per version; dismissing it records [_dismissedCode] so the
  ///              periodic poll does not nag the operator every 15 minutes.
  ///  * none    — hide, unless a forced notice is currently on screen from an older
  ///              verdict that has since been withdrawn.
  Future<void> _checkUpdate({bool allowRetry = true}) async {
    if (!updatesSupported) return;
    final info = await UpdateBridge.check();
    if (!mounted) return;

    // A manifest that could not be reached carries no information — leave whatever is on
    // screen alone rather than collapsing a forced gate because of a bad signal.
    //
    // But retry once, because the observed cold-start failure was silence, not a bad
    // network: the very first probe sometimes never left the process, and without a retry
    // the app would sit on a stale verdict until the 15-minute poll or the next resume.
    if (!info.reachable) {
      if (allowRetry) {
        await Future<void>.delayed(const Duration(seconds: 4));
        if (mounted) await _checkUpdate(allowRetry: false);
      }
      return;
    }

    final latest = info.latestCode ?? 0;
    // Visibility is a pure function of the manifest and the operator's dismissal.
    //
    // An earlier version also required `!_updateVisible` here, which inverted on itself:
    // while the popup was on screen every re-check computed "should be hidden" and closed
    // it — including the resume that follows the installer. That is why the popup kept
    // vanishing and coming back instead of staying put until it was dealt with.
    final shouldShow = info.blocked ||
        (info.updateAvailable && latest != _dismissedCode);

    final changed = shouldShow != _updateVisible ||
        info.blocked != (_updateInfo?.blocked ?? false) ||
        latest != (_updateInfo?.latestCode ?? 0);

    if (!changed) return;
    setState(() {
      _updateInfo = info;
      _updateVisible = shouldShow;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _updateTimer?.cancel();
    _statusVN.dispose();
    _bearingVN.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> _load() async {
    final settings = await AppSettings.load();
    final spots = await SpotStore.load();
    final status = await MockBridge.status();

    if (!mounted) return;
    _statusVN.value = status;
    setState(() {
      _source = settings.source;
      _target = status.running ? LatLng(status.lat, status.lng) : settings.target;
      _follow = settings.follow;
      // No demo points: the list starts empty and only holds what the operator saves.
      _spots = spots;
      _status = status;
      _running = status.running;
      _loaded = true;
    });
    // The map may already exist by the time prefs resolve (it is built on the first
    // frame behind the splash). Assigning `_target` alone does not move a live camera,
    // so the position is pushed explicitly once the real value is known.
    _recenterOnTarget();
  }

  /// Normalises a raw camera rotation to -180…180 and publishes it.
  ///
  /// The raw value is whatever the gesture maths produced — it can drift past ±360 over
  /// a long session. [normalizeRotation] is the single definition of "canonical", shared
  /// with the tests so the compass threshold and the reset path cannot disagree.
  void _publishBearing(double raw) {
    final deg = normalizeRotation(raw);
    if (_bearingVN.value != deg) _bearingVN.value = deg;
  }

  /// Snaps the camera back to north-up. The compass button's whole job.
  void _resetNorth() {
    if (!_mapReady) return;
    try {
      // `rotate` takes degrees, not radians — the camera reports degrees too, so the
      // compass and this call speak the same unit.
      _map.rotate(0);
      _publishBearing(0);
    } catch (_) {
      // Controller already disposed (shutdown race), nothing to reset.
    }
  }

  /// Moves the camera to [_target] if the map is alive and not already there.
  ///
  /// Split out because it runs from three places — after load, after a watchdog revive,
  /// and after a resumed service reports a different point — and a duplicated
  /// `_map.move` in each is how the camera silently drifts out of sync with the pin.
  ///
  /// [zoom] defaults to the live camera zoom, so picking a saved point does not reset a
  /// zoom level the operator had adjusted. Startup passes [_zoom] explicitly because
  /// there is no live camera to read from yet.
  void _recenterOnTarget({double? zoom}) {
    if (!_mapReady) return;
    try {
      final current = _map.camera.center;
      final targetZoom = zoom ?? _map.camera.zoom;
      final atTarget = (current.latitude - _target.latitude).abs() < 2e-6 &&
          (current.longitude - _target.longitude).abs() < 2e-6;
      if (!atTarget) _map.move(_target, targetZoom);
    } catch (_) {
      // The controller throws if the map was disposed between the check and the call;
      // that is a shutdown race, not a positioning failure.
    }
  }

  void _persist() {
    AppSettings(source: _source, target: _target, follow: _follow).save();
  }

  /// Polls the native side but only rebuilds the widget tree when something the
  /// tree actually shows changed. The map is the expensive subtree; a status tick
  /// must never repaint it.
  ///
  /// The poll is cheap on purpose: it reads only the volatile service fields. The
  /// AppOps gate (`isMockAppSelected`) is *not* re-read every tick — that costs a
  /// binder round-trip per second and its state only changes when the operator
  /// leaves the app, which [_onResume] already handles.
  Future<void> _refreshStatus() async {
    if (!MockBridge.isSupported) return;
    final status = await MockBridge.status();
    if (!mounted) return;

    _statusVN.value = status;

    // A service takes a beat to register as foreground; a poll that lands in that
    // window must not flip the button back and look like a refusal.
    final withinStartGrace = !status.running &&
        _running &&
        _startedAt != null &&
        DateTime.now().difference(_startedAt!) < const Duration(seconds: 3);

    final runningChanged = status.running != _running && !withinStartGrace;
    final moved = status.running &&
        (status.lat != _target.latitude || status.lng != _target.longitude);
    final gateChanged = status.mockSelected != _status.mockSelected;
    final healthChanged = status.health.length != _status.health.length;

    if (runningChanged || moved || gateChanged || healthChanged) {
      setState(() {
        _status = status;
        _running = status.running;
        if (moved) _target = LatLng(status.lat, status.lng);
      });
      if (moved && _follow) _recenterOnTarget();
    }

    final error = status.error;
    if (error != null && error != _lastError) {
      _lastError = error;
      _toast(error);
    }

    // Watchdog: the service claims to be running but has stopped delivering fixes.
    // The native alarm receiver is the primary revive path (it works while the process
    // is frozen); this loop only catches the case where the alarm itself was lost, e.g.
    // exact-alarm access revoked mid-session.
    if (status.running && status.stale) {
      final now = DateTime.now();
      if (_lastWatchdogAt == null ||
          now.difference(_lastWatchdogAt!) > const Duration(seconds: 6)) {
        _lastWatchdogAt = now;
        unawaited(_reviveService());
      }
    }
  }

  /// Re-issues start with the point the user chose. Does not touch the UI state.
  Future<void> _reviveService() async {
    if (_reviving) return;
    _reviving = true;
    try {
      await MockBridge.start(
        MockRequest(lat: _target.latitude, lng: _target.longitude),
      );
    } catch (_) {
      // A failed revive is not presented as an error: the next watchdog pass retries.
    } finally {
      _reviving = false;
    }
  }

  // --------------------------------------------------------------- actions

  Future<void> _start() async {
    if (!MockBridge.isSupported) {
      _toast('Mocking hanya jalan di Android.');
      return;
    }
    if (_starting) return;
    setState(() => _starting = true);

    try {
      var granted = await MockBridge.hasLocationPermission();
      if (!granted) granted = await MockBridge.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        _toast('Izin lokasi belum diberikan — buka Diagnosa → Izin lokasi.');
        return;
      }

      final selected = await MockBridge.isMockAppSelected();
      if (!mounted) return;
      if (!selected) {
        await _showGateDialog();
        return;
      }

      _startedAt = DateTime.now();
      await MockBridge.start(MockRequest(
        lat: _target.latitude,
        lng: _target.longitude,
      ));
      if (!mounted) return;
      setState(() => _running = true);

      // Confirm the service actually came up instead of trusting the intent.
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!mounted) return;
        final status = await MockBridge.status();
        if (!mounted) return;
        if (status.running) {
          _statusVN.value = status;
          setState(() => _status = status);
          await _offerBatteryExemption(status);
          return;
        }
      }
      if (!mounted) return;
      setState(() => _running = false);
      _toast('Service belum terdeteksi — coba sekali lagi, atau buka Diagnosa.');
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'MOCK_NOT_ALLOWED') {
        await _showGateDialog();
        return;
      }
      _toast(e.message ?? 'Gagal mulai (${e.code})');
    } catch (e) {
      if (!mounted) return;
      _toast('Gagal mulai: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// One-time nudge, fired at the first successful start.
  ///
  /// Two separate grants matter and neither is optional on ColorOS:
  ///  - battery optimisation exemption (AOSP whitelist), and
  ///  - exact-alarm access (the anti-freeze watchdog).
  ///
  /// Missing either one reproduces the reported symptom: fixes stop a couple of minutes
  /// in and the client falls back to the real GPS.
  Future<void> _offerBatteryExemption(MockStatus status) async {
    final needsBattery = !status.batteryUnrestricted;
    final needsAlarm = !status.exactAlarmGranted;
    if (!needsBattery && !needsAlarm) return;
    if (await AppSettings.batteryPromptShown()) return;
    await AppSettings.markBatteryPromptShown();
    if (!mounted) return;

    final open = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Biarkan tetap jalan'),
        content: const Text(
          'Wajib. Tanpa ini, Android membekukan aplikasi setelah layar mati dan '
          'titik balik ke lokasi asli dalam 1–2 menit.\n\n'
          'Tekan "Atur", lalu pilih IZINKAN pada dialog "Izinkan aplikasi selalu '
          'berjalan di background?".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Nanti'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'battery'),
            child: const Text('Atur'),
          ),
        ],
      ),
    );
    if (!mounted) return;

    if (open == 'battery') {
      // Chain them: the battery screen is the one that actually fixes the freeze, so
      // it goes first. The exact-alarm screen is offered only if still missing, and
      // only after the user has come back from the previous screen.
      await MockBridge.openBatterySettings();
      if (!mounted) return;
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      final refreshed = await MockBridge.status();
      if (!mounted) return;
      if (!refreshed.exactAlarmGranted) {
        final alarm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Izinkan alarm tepat waktu'),
            content: const Text(
              'Untuk menjaga titik saat aplikasi di belakang, aplikasi perlu '
              'izin "Alarm & pengingat".',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Lewati'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Izinkan'),
              ),
            ],
          ),
        );
        if (alarm == true) await MockBridge.openExactAlarmSettings();
      }
    }
  }

  Future<void> _stop() async {
    await MockBridge.stop();
    if (!mounted) return;
    setState(() => _running = false);
    await _refreshStatus();
  }

  void _setTarget(LatLng point, {bool moveCamera = true}) {
    setState(() => _target = point);
    if (moveCamera) _recenterOnTarget();
    if (_running) {
      MockBridge.update(lat: point.latitude, lng: point.longitude);
    }
    _persist();
  }

  Future<void> _editCoordinates() async {
    final point = await showDialog<LatLng>(
      context: context,
      builder: (_) => _CoordinateDialog(initial: _target),
    );
    if (point == null || !mounted) return;
    _setTarget(point);
  }

  Future<void> _locateMe() async {
    var granted = await MockBridge.hasLocationPermission();
    if (!granted) granted = await MockBridge.requestPermissions();
    if (!mounted) return;
    if (!granted) {
      _toast('Izin lokasi ditolak.');
      return;
    }
    try {
      final point = await MockBridge.realLocation();
      if (!mounted) return;
      if (point == null) {
        _toast('GPS asli belum dapat fix.');
        return;
      }
      _setTarget(point);
    } on PlatformException catch (e) {
      _toast(e.message ?? 'Gagal membaca lokasi asli (${e.code}).');
    }
  }

  Future<void> _search() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    try {
      final results = await Geocoder.search(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
      if (results.isEmpty) _toast('Tidak ada hasil untuk "$query".');
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      _toast('Pencarian gagal: $e');
    }
  }

  void _onMapTap(TapPosition _, LatLng point) => _setTarget(point);

  Future<void> _saveSpot() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        title: 'Simpan titik',
        label: 'Nama',
        initialValue: 'Titik ${_spots.length + 1}',
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    final spot = Spot.at(_target, name.trim());
    setState(() {
      _spots = [spot, ..._spots];
    });
    try {
      await SpotStore.save(_spots);
      _toast('Titik "${spot.name}" disimpan.');
    } catch (e) {
      _toast('Gagal menyimpan titik: $e');
    }
  }

  Future<void> _renameSpot(Spot spot) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        title: 'Ganti nama',
        label: 'Nama',
        initialValue: spot.name,
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    final updated = spot.copyWith(name: name.trim());
    setState(() => _spots = _spots.map((s) => s.id == spot.id ? updated : s).toList());
    try {
      await SpotStore.save(_spots);
    } catch (e) {
      _toast('Gagal menyimpan: $e');
    }
  }

  Future<void> _deleteSpot(Spot spot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus "${spot.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _spots = _spots.where((s) => s.id != spot.id).toList(growable: true);
    });
    try {
      await SpotStore.save(_spots);
    } catch (e) {
      _toast('Gagal menghapus titik: $e');
    }
  }

  Future<void> _showGateDialog() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aktifkan lokasi tiruan'),
        content: const Text(
          '1. Buka Opsi Pengembang.\n'
          '2. Cari "Pilih aplikasi lokasi tiruan".\n'
          '3. Pilih aplikasi ini.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Nanti')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Buka pengaturan'),
          ),
        ],
      ),
    );
    if (open == true) await MockBridge.openDeveloperSettings();
  }

  Future<void> _pickSource() async {
    final picked = await showMapSourceSheet(context, _source);
    if (picked == null || !mounted) return;
    setState(() => _source = picked);
    _persist();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  // ------------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // The map is not constructed until prefs resolve. Building it earlier pins
          // `initialCenter` to the placeholder coordinate and starts fetching tiles for
          // the wrong region, so reopening the app would show Jakarta for a beat even
          // when the camera is corrected afterwards.
          if (_loaded) _buildMap() else const ColoredBox(color: Color(0xFF081014)),
          _buildSearchBar(),
          if (_searchResults.isNotEmpty) _buildSearchResults(),
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // The compass sits above the card so a rotated map always has a visible way
              // back to north. Growing the column upward (rather than overlaying) means
              // the card keeps its exact position when the button appears.
              children: [
                _buildCompass(),
                _buildCard(),
              ],
            ),
          ),
          // Fades out once `_load()` finishes. Sits on top of everything, including a
          // half-built map, so the first painted frame is never a grey rectangle.
          if (!_splashGone)
            SplashOverlay(
              visible: !_loaded,
              onDismissed: () {
                if (mounted) setState(() => _splashGone = true);
              },
            ),
          // Popup layer, sibling to the content above — never a wrapper around it. See
          // UpdateGate's header: re-parenting the Scaffold broke map compositing under an
          // alpha scrim on this device.
          if (_updateVisible && _updateInfo != null && _splashGone)
            UpdateGate(
              info: _updateInfo!,
              onDismiss: _updateInfo!.blocked
                  ? null
                  : () => setState(() {
                        _updateVisible = false;
                        // Remember which version was dismissed so the 15-minute poll does
                        // not re-open the same notice the operator already closed.
                        _dismissedCode = _updateInfo!.latestCode;
                      }),
              // The platform confirmed the install. Drop the popup now rather than waiting
              // for the next poll — this is what stops "the popup keeps coming back" when
              // the process survives the update instead of being replaced.
              onInstalled: () {
                if (!mounted) return;
                setState(() {
                  _updateVisible = false;
                  _updateInfo = null;
                });
                _checkUpdate();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    return RepaintBoundary(
      child: FlutterMap(
        mapController: _map,
        options: MapOptions(
          // `initialCenter` is read exactly once, when the map is first constructed.
          // `_target` starts at [_fallback] and is replaced by the persisted value in
          // `_load()`, which runs after the first frame — so a map built immediately
          // would lock its camera on the fallback coordinate and never move, which is
          // why reopening the app landed on Jakarta regardless of the saved target.
          // [_buildMapShell] keeps this widget out of the tree until the load resolves.
          initialCenter: _target,
          initialZoom: _zoom,
          minZoom: 2,
          maxZoom: _source.maxZoom.toDouble(),
          // Google/Esri land tone: a tile that has not arrived yet is invisible
          // instead of flashing grey.
          backgroundColor: const Color(0xFFE5E3DF),
          onMapReady: () {
            _mapReady = true;
            // If prefs resolved before the map did, the camera still sits on the
            // placeholder coordinate from construction — move it to the real target.
            _recenterOnTarget();
            // Seed the compass from the camera rather than assuming zero: `onPositionChanged`
            // only fires on a change, so a map that starts rotated would otherwise show no
            // reset button until the operator happened to move it.
            _publishBearing(_map.camera.rotation);
          },
          onTap: _onMapTap,
          onPositionChanged: (camera, hasGesture) =>
              _publishBearing(camera.rotation),
          interactionOptions: const InteractionOptions(
            // `all` includes `InteractiveFlag.rotate`; the map was previously pinned to
            // `all & ~rotate`, which is why a two-finger twist did nothing at all.
            flags: InteractiveFlag.all,
            // Without the gesture race, rotate, pan and zoom all act at once and the
            // twist fights the drag. With it, exactly one gesture wins per movement.
            enableMultiFingerGestureRace: true,
            // Library default is 20°, which needs a near-quarter turn before anything
            // happens on a phone. 15° is still clearly deliberate, but reachable.
            rotationThreshold: 15.0,
          ),
        ),
        children: [
          TileLayer(
            key: ValueKey<String>(_source.id),
            urlTemplate: _source.urlTemplate,
            fallbackUrl: _source.fallbackUrl,
            subdomains: _source.subdomains,
            userAgentPackageName: 'com.ajiputra.fake_gps',
            maxNativeZoom: _source.maxZoom,
            maxZoom: _source.maxZoom.toDouble(),
            panBuffer: 1,
            keepBuffer: 3,
            tileDisplay: const TileDisplay.fadeIn(
              duration: Duration(milliseconds: 120),
            ),
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: _target,
                width: 46,
                height: 46,
                child: _Pin(active: _running),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Material(
          elevation: 6,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(18),
          color: theme.colorScheme.surface,
          child: TextField(
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Cari tempat atau alamat',
              prefixIcon: const Icon(Icons.search, size: 22),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (_searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchResults = <Spot>[]);
                          },
                        )),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
      ),
    );
  }

  /// Brand strip that sits under the map, inside the bottom card rather than over
  /// the map itself.
  Widget _buildBrand() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 4, 11, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Image.asset('assets/images/logo.png'),
          ),
          const SizedBox(width: 6),
          Text(
            'Powered by Ajiputra-tech',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9.5,
              color: theme.colorScheme.primary,
              letterSpacing: 0.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    final theme = Theme.of(context);
    return Positioned(
      top: MediaQuery.of(context).padding.top + 68,
      left: 12,
      right: 12,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _searchResults.length,
            itemBuilder: (context, index) {
              final spot = _searchResults[index];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined, size: 20),
                title: Text(spot.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${fmtCoord(spot.lat)}, ${fmtCoord(spot.lng)}',
                    style: theme.textTheme.labelSmall),
                onTap: () {
                  setState(() => _searchResults = <Spot>[]);
                  _searchCtrl.clear();
                  _setTarget(spot.point);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// "Back to north" control. Renders nothing at all while the map is upright.
  ///
  /// A twirling needle would need the sign of `MapCamera.rotation` mapped correctly to
  /// screen space to avoid pointing the wrong way; a fixed arrow that only resets is
  /// unambiguous and cannot lie. It appears the moment the camera leaves north and
  /// disappears when it returns, so it never takes space it does not need.
  Widget _buildCompass() {
    return ValueListenableBuilder<double>(
      valueListenable: _bearingVN,
      builder: (context, bearing, _) {
        if (bearing.abs() < 0.5) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(right: 24, bottom: 10),
          child: Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message: 'Putar ke utara',
              child: Material(
                color: scheme.surface,
                elevation: 6,
                shadowColor: Colors.black54,
                shape: CircleBorder(
                  side: BorderSide(
                    color: scheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _resetNorth,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    // `navigation` is a solid arrow pointing up: north-up, north.
                    child: Icon(
                      Icons.navigation,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard() {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.35)),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, 6)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeaderRow(),
            const SizedBox(height: 6),
            _buildCoordinateRow(),
            const SizedBox(height: 12),
            _buildGateHint(),
            _buildPrimaryButton(),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildBrand(),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _source.attribution,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Image.asset('assets/images/logo.png'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ValueListenableBuilder<MockStatus>(
            valueListenable: _statusVN,
            builder: (context, status, _) => _StatusPill(
              running: status.running,
              attached: status.health.where((h) => h.attached).length,
              total: status.health.isEmpty ? 3 : status.health.length,
            ),
          ),
        ),
        _iconButton(
          icon: Icons.my_location,
          tooltip: 'Lokasi asli',
          onPressed: _locateMe,
        ),
        _iconButton(
          icon: Icons.layers_outlined,
          tooltip: 'Sumber peta',
          onPressed: _pickSource,
        ),
        // Saved points live behind this button now instead of occupying a card in the
        // bottom sheet — the map stays the subject, and the list is one tap away.
        _iconButton(
          icon: Icons.bookmarks_outlined,
          tooltip: 'Lokasi tersimpan',
          onPressed: _openSpotsSheet,
          badge: _spots.isEmpty ? null : _spots.length,
        ),
      ],
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    int? badge,
  }) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        if (badge != null)
          Positioned(
            right: 2,
            top: 2,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 15),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$badge',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCoordinateRow() {
    final theme = Theme.of(context);

    return InkWell(
      onTap: _editCoordinates,
      onLongPress: () async {
        await Clipboard.setData(
          ClipboardData(text: '${fmtCoord(_target.latitude)}, ${fmtCoord(_target.longitude)}'),
        );
        _toast('Koordinat disalin.');
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.place_outlined, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${fmtCoord(_target.latitude)}, ${fmtCoord(_target.longitude)}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            Icon(Icons.edit_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// Bottom sheet listing every saved point.
  ///
  /// This replaced the card that used to sit inside the main bottom sheet. The list is
  /// opened on demand from the bookmarks button beside the layer button, so the map card
  /// stays compact and the points get the full screen height when they are needed.
  Future<void> _openSpotsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => _SpotsSheet(
        spots: _spots,
        target: _target,
        onPick: (spot) {
          Navigator.pop(sheetContext);
          _setTarget(spot.point);
        },
        onRename: (spot) async {
          await _renameSpot(spot);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
          if (mounted) await _openSpotsSheet();
        },
        onDelete: (spot) async {
          await _deleteSpot(spot);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
          if (mounted) await _openSpotsSheet();
        },
        onSaveCurrent: () async {
          Navigator.pop(sheetContext);
          await _saveSpot();
        },
      ),
    );
  }

  Widget _buildGateHint() {
    if (!_loaded) return const SizedBox.shrink();
    final theme = Theme.of(context);

    // Two independent blockers, in the order that matters:
    //  1. mock-app slot not selected  -> mocking cannot start at all
    //  2. battery whitelist missing   -> mocking starts, then dies in 1–2 minutes
    // The second one is the failure that keeps coming back because starting *looks*
    // fine, so it gets its own persistent, tappable row.
    if (_status.mockSelected && _status.batteryUnrestricted) {
      return const SizedBox.shrink();
    }

    final (String label, VoidCallback onTap) = !_status.mockSelected
        ? ('Pilih app ini di Opsi pengembang → lokasi tiruan', _showGateDialog)
        : ('Baterai: titik akan mati sendiri. Izinkan selalu berjalan.', _openBattery);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withOpacity(0.35),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, style: theme.textTheme.labelSmall),
              ),
              Text('Atur', style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              )),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the per-app "allow background" dialog, then re-reads the gate so the
  /// warning row disappears the moment the grant lands.
  Future<void> _openBattery() async {
    await MockBridge.openBatterySettings();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    await MockBridge.refreshGates();
    final status = await MockBridge.status();
    if (!mounted) return;
    _statusVN.value = status;
    setState(() => _status = status);
  }

  Widget _buildPrimaryButton() {
    final theme = Theme.of(context);

    return SizedBox(
      height: 50,
      child: FilledButton.icon(
        onPressed: _starting ? null : (_running ? _stop : _start),
        icon: _starting
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onPrimary,
                ),
              )
            : Icon(_running ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 22),
        label: Text(
          _starting ? 'Menyalakan…' : (_running ? 'Stop' : 'Mulai mocking'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          backgroundColor:
              _running ? theme.colorScheme.errorContainer : theme.colorScheme.primary,
          foregroundColor:
              _running ? theme.colorScheme.onErrorContainer : theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}

/// Live status read-out. Rebuilds on its own so a status tick never repaints
/// the map subtree.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.running,
    required this.attached,
    required this.total,
  });

  final bool running;
  final int attached;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: running ? theme.colorScheme.primary : theme.colorScheme.outline,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            running ? 'Mocking · $attached/$total' : 'Siap',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: running
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Text prompt that owns its controller for the lifetime of the route.
///
/// Disposing a controller right after `Navigator.pop` throws
/// `'_dependents.isEmpty': is not true` because the field is still mounted while
/// the dialog animates out — hence the dedicated stateful widget.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.initialValue,
  });

  final String title;
  final String label;
  final String initialValue;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _CoordinateDialog extends StatefulWidget {
  const _CoordinateDialog({required this.initial});

  final LatLng initial;

  @override
  State<_CoordinateDialog> createState() => _CoordinateDialogState();
}

class _CoordinateDialogState extends State<_CoordinateDialog> {
  late final TextEditingController _lat =
      TextEditingController(text: fmtCoord(widget.initial.latitude));
  late final TextEditingController _lng =
      TextEditingController(text: fmtCoord(widget.initial.longitude));
  String? _error;

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  void _apply() {
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lng = double.tryParse(_lng.text.trim().replaceAll(',', '.'));
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      setState(() => _error = 'Koordinat tidak valid (lat ±90, lng ±180).');
      return;
    }
    Navigator.pop(context, LatLng(lat, lng));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Koordinat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _lat,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Latitude'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _lng,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Longitude'),
            onSubmitted: (_) => _apply(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: _apply, child: const Text('Terapkan')),
      ],
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active ? theme.colorScheme.primary : theme.colorScheme.tertiary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.25) : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
            // A white halo keeps the pin legible over the light Google basemap,
            // where the teal ring alone barely separates from the land tone.
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(Icons.location_on, size: 18, color: color),
        ),
        Container(width: 2, height: 6, color: color),
      ],
    );
  }
}

/// The saved-points list, shown as a modal sheet.
///
/// Stateful only so that a rename or delete inside the sheet redraws the remaining
/// rows before the parent reopens it — the parent owns the source of truth and passes
/// a fresh list each time, but the sheet must not render stale data in the frame
/// between the pop and the reopen.
class _SpotsSheet extends StatelessWidget {
  const _SpotsSheet({
    required this.spots,
    required this.target,
    required this.onPick,
    required this.onRename,
    required this.onDelete,
    required this.onSaveCurrent,
  });

  final List<Spot> spots;
  final LatLng target;
  final void Function(Spot) onPick;
  final void Function(Spot) onRename;
  final void Function(Spot) onDelete;
  final VoidCallback onSaveCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.72;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.bookmarks_outlined,
                      size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'Lokasi tersimpan',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${spots.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onSaveCurrent,
                    icon: const Icon(Icons.add_location_alt_outlined, size: 17),
                    label: const Text('Simpan titik ini'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (spots.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 34),
                child: Column(
                  children: [
                    Icon(Icons.place_outlined,
                        size: 34,
                        color: theme.colorScheme.onSurfaceVariant
                            .withOpacity(0.5)),
                    const SizedBox(height: 10),
                    Text(
                      'Belum ada titik tersimpan',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Pilih lokasi di peta, lalu tekan "Simpan titik ini".',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: spots.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                  itemBuilder: (context, index) {
                    final spot = spots[index];
                    final active = (target.latitude - spot.lat).abs() < 1e-9 &&
                        (target.longitude - spot.lng).abs() < 1e-9;
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.only(left: 20, right: 6),
                      leading: Icon(
                        active
                            ? Icons.radio_button_checked
                            : Icons.place_outlined,
                        size: 20,
                        color: active
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        spot.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text(
                        '${fmtCoord(spot.lat)}, ${fmtCoord(spot.lng)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Ganti nama',
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onRename(spot),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Hapus',
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            color: theme.colorScheme.error,
                            onPressed: () => onDelete(spot),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      onTap: () => onPick(spot),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
