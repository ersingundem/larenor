import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../kiosk_remote/runtime/managed_tablet_app_view_port.dart';
import '../../kiosk_remote/runtime/managed_tablet_credential_store.dart';
import '../../kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import '../../kiosk_remote/runtime/managed_tablet_runtime_scope.dart';
import '../domain/kiosk_remote_view.dart';

class KioskControlledViewScreen extends ConsumerStatefulWidget {
  const KioskControlledViewScreen({super.key});

  @override
  ConsumerState<KioskControlledViewScreen> createState() =>
      _KioskControlledViewScreenState();
}

class _KioskControlledViewScreenState
    extends ConsumerState<KioskControlledViewScreen>
    with WidgetsBindingObserver {
  final _boundaryKey = GlobalKey();
  late final ManagedTabletAppViewPort _port;
  late final KioskRemoteViewController _controller;
  ManagedTabletEnrollment? _enrollment;
  ManagedTabletTelemetry? _telemetry;
  Timer? _frames;
  String? _error;
  bool _foreground = true;
  bool _loading = false;
  bool _working = false;
  bool _active = false;
  bool _capturing = false;
  int _authorityEpoch = 1;
  int _captureTicks = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _port = ManagedTabletAppViewPort(
      owner: ref.read(managedTabletRuntimeOwnerProvider),
    );
    _controller = KioskRemoteViewController(
      port: _port,
      isCurrent: (candidate) => candidate == _authority,
      requestIds: _requestId,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  KioskDeviceAuthority? get _authority {
    final enrollment = _enrollment;
    if (enrollment == null || _authorityEpoch < 1) return null;
    return KioskDeviceAuthority(
      coreId: enrollment.coreId,
      homeId: enrollment.homeId,
      accountId: sha256.convert(utf8.encode(enrollment.accountId)).toString(),
      deviceId: enrollment.deviceId,
      deviceRevision: enrollment.revision,
      policyRevision: enrollment.revision,
      sessionEpoch: _authorityEpoch,
      routeEpoch: _authorityEpoch,
      lifecycleEpoch: _authorityEpoch,
    );
  }

  KioskRemoteViewContext? _trusted({
    required bool routeVisible,
    required bool interactionActive,
  }) {
    final authority = _authority;
    if (authority == null) return null;
    return KioskRemoteViewContext(
      binding: authority,
      foreground: _foreground,
      routeVisible: routeVisible,
      interactionActive: interactionActive,
      sensitivity: KioskScreenSensitivity.ordinary,
      projectionConsentActive: false,
      projectionConsentRevision: null,
    );
  }

  bool get _routeVisible =>
      mounted && ModalRoute.of(context)?.isCurrent == true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      unawaited(_retire(updateState: mounted));
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    if (_loading || _working || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final enrollment = await ref
          .read(managedTabletCredentialStoreProvider)
          .read();
      if (enrollment == null ||
          !enrollment.expiresAt.isAfter(DateTime.now().toUtc()) ||
          (!enrollment.scopes.contains('read') &&
              !enrollment.scopes.contains('admin'))) {
        throw StateError('remote_view_pairing_unavailable');
      }
      final telemetry = await ref
          .read(managedTabletRuntimeOwnerProvider)
          .readRemoteViewTelemetry();
      if (!mounted) return;
      setState(() {
        _enrollment = enrollment;
        _telemetry = telemetry;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _enrollment = null;
        _telemetry = null;
        _error = AppLocalizations.of(context).kioskControlledViewUnavailable;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start() async {
    if (_working || _active || !_foreground || !_routeVisible) return;
    if (_enrollment == null || _telemetry == null) await _load();
    final trusted = _trusted(routeVisible: true, interactionActive: true);
    if (!mounted || trusted == null || !_foreground || !_routeVisible) return;
    final preview = _controller.prepare(
      KioskRemoteViewMode.appSurface,
      trusted,
    );
    if (preview.status != KioskRemoteViewStatus.needsConfirmation) {
      _controller.invalidate();
      setState(
        () => _error = AppLocalizations.of(context).kioskControlledViewFailed,
      );
      return;
    }
    final l = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l.kioskControlledViewConfirmTitle),
        content: Text(l.kioskControlledViewConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.commonCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.kioskControlledViewConfirm),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !_foreground || !_routeVisible) {
      _controller.invalidate();
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final receipt = await _controller.confirm(
        preview,
        _trusted(routeVisible: true, interactionActive: true)!,
      );
      if (!mounted || receipt.status != KioskRemoteViewStatus.active) {
        _controller.invalidate();
        if (mounted) {
          setState(() => _error = l.kioskControlledViewFailed);
        }
        return;
      }
      setState(() => _active = true);
      _frames?.cancel();
      _frames = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_capture()),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_capture());
      });
    } catch (_) {
      if (mounted) setState(() => _error = l.kioskControlledViewFailed);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _capture() async {
    if (!_active || _capturing || !_foreground || !_routeVisible) {
      if (_active && (!_foreground || !_routeVisible)) {
        await _retire(updateState: mounted);
      }
      return;
    }
    _capturing = true;
    try {
      _captureTicks += 1;
      if (_captureTicks % 5 == 0) {
        final telemetry = await ref
            .read(managedTabletRuntimeOwnerProvider)
            .readRemoteViewTelemetry();
        if (!mounted || !_active) return;
        setState(() => _telemetry = telemetry);
        await WidgetsBinding.instance.endOfFrame;
      }
      final boundary = _boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.debugNeedsPaint) {
        final png = await _encodeBoundary(boundary, 0.5);
        if (png == null) throw StateError('remote_view_capture_failed');
        final bytes = png.length <= managedTabletRemoteViewMaxFrameBytes
            ? png
            : await _encodeBoundary(boundary, 0.35);
        if (bytes == null ||
            bytes.length > managedTabletRemoteViewMaxFrameBytes) {
          throw StateError('remote_view_frame_too_large');
        }
        await _port.publishPng(bytes);
      }
    } catch (_) {
      await _retire(updateState: mounted);
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).kioskControlledViewFailed,
        );
      }
    } finally {
      _capturing = false;
    }
  }

  Future<List<int>?> _encodeBoundary(
    RenderObject? candidate,
    double pixelRatio,
  ) async {
    if (candidate is! RenderRepaintBoundary) return null;
    final image = await candidate.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _retire({required bool updateState}) async {
    _frames?.cancel();
    _frames = null;
    if (_port.activeRequestId != null) {
      final trusted = _trusted(routeVisible: false, interactionActive: false);
      if (trusted != null) await _controller.reconcile(trusted);
    }
    try {
      _controller.invalidate();
    } on StateError {
      // Reconcile already removed local frame authority before stopping MQTT.
    }
    _authorityEpoch += 1;
    _captureTicks = 0;
    _active = false;
    if (updateState && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frames?.cancel();
    unawaited(_retire(updateState: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l.kioskControlledViewTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Text(l.kioskControlledViewHint, style: AppText.body),
                ),
                RepaintBoundary(
                  key: _boundaryKey,
                  child: ColoredBox(
                    color: CupertinoColors.systemGroupedBackground.resolveFrom(
                      context,
                    ),
                    child: SettingsSection(
                      header: Text(l.kioskControlledViewPanelTitle),
                      footer: Text(l.kioskControlledViewPrivacy),
                      children: _telemetry == null
                          ? [
                              const Padding(
                                padding: EdgeInsets.all(20),
                                child: Center(
                                  child: CupertinoActivityIndicator(),
                                ),
                              ),
                            ]
                          : _deviceRows(l, _telemetry!),
                    ),
                  ),
                ),
                SettingsSection(
                  header: Text(l.kioskControlledViewFullProjectionTitle),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        l.kioskControlledViewFullProjectionUnavailable,
                        style: AppText.body,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _active
                        ? l.kioskControlledViewActive
                        : l.kioskControlledViewInactive,
                    textAlign: TextAlign.center,
                    style: AppText.headline,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: CupertinoButton.filled(
                    onPressed: _working || _loading || !_foreground
                        ? null
                        : _active
                        ? () => _retire(updateState: true)
                        : _start,
                    child: _working || _loading
                        ? const CupertinoActivityIndicator()
                        : Text(
                            _active
                                ? l.kioskControlledViewStop
                                : l.kioskControlledViewStart,
                          ),
                  ),
                ),
                CupertinoButton(
                  onPressed: _working || _active ? null : _load,
                  child: Text(l.commonRefresh),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _deviceRows(
    AppLocalizations l,
    ManagedTabletTelemetry value,
  ) => [
    _row(l.kioskControlledViewBattery, '${value.batteryPercent}%'),
    _row(
      l.kioskControlledViewCharging,
      value.charging ? l.commonYes : l.commonNo,
    ),
    _row(l.kioskControlledViewNetwork, value.network),
    _row(
      l.kioskControlledViewAppVersion,
      '${value.appVersion} (${value.appBuild})',
    ),
    _row(l.kioskControlledViewKioskState, value.kioskState),
    _row(
      l.kioskControlledViewMemory,
      '${value.memoryUsedMb} / ${value.memoryLimitMb} MB',
    ),
    _row(l.kioskControlledViewUptime, _duration(value.processUptimeSeconds)),
  ];

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppText.body)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(value, textAlign: TextAlign.end, style: AppText.headline),
        ),
      ],
    ),
  );

  static String _duration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }

  static String _requestId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
