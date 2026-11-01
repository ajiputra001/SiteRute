import 'dart:io';

import 'package:flutter/services.dart';

/// A manifest as described by the release server, plus the local install it is compared
/// against. Everything here is what the force-update gate needs and nothing more.
class UpdateInfo {
  const UpdateInfo({
    required this.reachable,
    required this.installedCode,
    required this.installedName,
    this.latestCode,
    this.latestName,
    this.notes,
    this.updateAvailable = false,
    this.blocked = false,
  });

  /// Whether the manifest could be fetched at all. A false value is *not* an update.
  final bool reachable;

  final int installedCode;
  final String installedName;
  final int? latestCode;
  final String? latestName;
  final String? notes;

  /// A newer build exists (forced or not).
  final bool updateAvailable;

  /// The app must refuse to be used until the update is installed.
  final bool blocked;

  static const UpdateInfo unknown = UpdateInfo(
    reachable: false,
    installedCode: 0,
    installedName: '?',
  );

  factory UpdateInfo.fromMap(Map<Object?, Object?> m) => UpdateInfo(
        reachable: m['reachable'] as bool? ?? false,
        installedCode: (m['installedCode'] as num?)?.toInt() ?? 0,
        installedName: m['installedName']?.toString() ?? '?',
        latestCode: (m['latestCode'] as num?)?.toInt(),
        latestName: m['latestName']?.toString(),
        notes: m['notes']?.toString(),
        updateAvailable: m['updateAvailable'] as bool? ?? false,
        blocked: m['blocked'] as bool? ?? false,
      );
}

/// Thin bridge over the native updater. The heavy work — HTTP, hashing, the installer
/// intent — stays in Kotlin; this class only marshals arguments.
class UpdateBridge {
  static const MethodChannel _ch =
      MethodChannel('com.ajiputra.fake_gps/control');

  /// Checks the manifest. Never throws: an unreachable server yields
  /// [UpdateInfo.unknown] and the gate stays open.
  static Future<UpdateInfo> check() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('checkUpdate');
      return r == null ? UpdateInfo.unknown : UpdateInfo.fromMap(r);
    } on MissingPluginException {
      // Running against an old native side (hot reload after a partial rebuild).
      return UpdateInfo.unknown;
    } catch (_) {
      return UpdateInfo.unknown;
    }
  }

  /// Downloads the pending APK. Returns the local path on success.
  static Future<({bool ok, String? path, String? error})> download() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('downloadUpdate');
      if (r == null) {
        return (ok: false, path: null, error: 'Respons kosong.');
      }
      return (
        ok: r['ok'] as bool? ?? false,
        path: r['path']?.toString(),
        error: r['error']?.toString(),
      );
    } on PlatformException catch (e) {
      return (ok: false, path: null, error: e.message ?? 'Unduhan gagal.');
    } catch (e) {
      return (ok: false, path: null, error: '$e');
    }
  }

  /// Launches PackageInstaller for a previously downloaded APK.
  static Future<bool> install(String path) async {
    try {
      return await _ch.invokeMethod<bool>('installUpdate', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> canInstall() async {
    try {
      return await _ch.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openInstallSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openInstallSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Retained for callers that want to know whether this build has anywhere to check.
  /// The native side owns the URL constant, so this only reports the platform.
  // ignore: unused_element
  static Future<bool> isUrlUnset() async => !Platform.isAndroid;
}
