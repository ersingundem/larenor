import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/core_infrastructure_evidence.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../server/data/larenor_server_api.dart';

enum CoreKeeneticCommandAction {
  guestWifiEnable,
  guestWifiDisable,
  clientInternetPause,
  clientInternetResume,
  wanReconnect,
}

enum CoreKeeneticCommandStatus { succeeded, failed, cancelled, unknown }

class CoreKeeneticCommandFailure implements Exception {
  const CoreKeeneticCommandFailure(this.code);
  final String code;
}

class CoreKeeneticCommandTarget {
  const CoreKeeneticCommandTarget({
    required this.coreId,
    required this.homeId,
    required this.resourceId,
    required this.resourceRevision,
    required this.aclRevision,
    required this.bindingId,
    required this.bindingRevision,
    required this.serviceId,
    required this.serviceRevision,
    required this.firmwareVersion,
    required this.firmwareRevision,
    required this.stateRevision,
    required this.targetKind,
    required this.targetId,
    required this.value,
  });

  factory CoreKeeneticCommandTarget.syntheticForTest({
    required String targetKind,
    required String targetId,
    required String value,
  }) => CoreKeeneticCommandTarget(
    coreId: '1' * 32,
    homeId: '2' * 32,
    resourceId: '3' * 32,
    resourceRevision: 3,
    aclRevision: 4,
    bindingId: '4' * 32,
    bindingRevision: 5,
    serviceId: '5' * 32,
    serviceRevision: 6,
    firmwareVersion: '5.0.4',
    firmwareRevision: 7,
    stateRevision: 8,
    targetKind: targetKind,
    targetId: targetId,
    value: value,
  );

  final String coreId, homeId, resourceId, bindingId, serviceId;
  final int resourceRevision,
      aclRevision,
      bindingRevision,
      serviceRevision,
      firmwareRevision,
      stateRevision;
  final String firmwareVersion, targetKind, targetId, value;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'resourceId': resourceId,
    'resourceRevision': resourceRevision,
    'aclRevision': aclRevision,
    'bindingId': bindingId,
    'bindingRevision': bindingRevision,
    'serviceId': serviceId,
    'serviceRevision': serviceRevision,
    'firmwareVersion': firmwareVersion,
    'firmwareRevision': firmwareRevision,
    'stateRevision': stateRevision,
    'targetKind': targetKind,
    'targetId': targetId,
    'value': value,
  };

  factory CoreKeeneticCommandTarget.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> || raw.length != 16) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final allowed = {
      'schemaVersion',
      'coreId',
      'homeId',
      'resourceId',
      'resourceRevision',
      'aclRevision',
      'bindingId',
      'bindingRevision',
      'serviceId',
      'serviceRevision',
      'firmwareVersion',
      'firmwareRevision',
      'stateRevision',
      'targetKind',
      'targetId',
      'value',
    };
    if (!allowed.every(raw.containsKey) || raw['schemaVersion'] != 1) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    String identity(String key) {
      final value = raw[key];
      if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw const CoreKeeneticCommandFailure('invalid_response');
      }
      return value;
    }

    int revision(String key) {
      final value = raw[key];
      if (value is! int || value < 1 || value > 9223372036854775807) {
        throw const CoreKeeneticCommandFailure('invalid_response');
      }
      return value;
    }

    String text(String key, int max) {
      final value = raw[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > max ||
          value.runes.any((rune) => rune < 32 || rune == 127)) {
        throw const CoreKeeneticCommandFailure('invalid_response');
      }
      return value;
    }

    final firmware = text('firmwareVersion', 80);
    if (!RegExp(r'^[2-5]\.').hasMatch(firmware)) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final kind = text('targetKind', 16);
    final value = text('value', 16);
    if (!{'guest_wifi', 'client', 'wan'}.contains(kind) ||
        !{
          'enabled',
          'disabled',
          'allowed',
          'paused',
          'online',
          'offline',
        }.contains(value)) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    return CoreKeeneticCommandTarget(
      coreId: identity('coreId'),
      homeId: identity('homeId'),
      resourceId: identity('resourceId'),
      resourceRevision: revision('resourceRevision'),
      aclRevision: revision('aclRevision'),
      bindingId: identity('bindingId'),
      bindingRevision: revision('bindingRevision'),
      serviceId: identity('serviceId'),
      serviceRevision: revision('serviceRevision'),
      firmwareVersion: firmware,
      firmwareRevision: revision('firmwareRevision'),
      stateRevision: revision('stateRevision'),
      targetKind: kind,
      targetId: text('targetId', 128),
      value: value,
    );
  }

  String get fingerprint => [
    coreId,
    homeId,
    resourceId,
    resourceRevision,
    aclRevision,
    bindingId,
    bindingRevision,
    serviceId,
    serviceRevision,
    firmwareVersion,
    firmwareRevision,
    stateRevision,
    targetKind,
    targetId,
    value,
  ].join('\u0000');
}

class CoreKeeneticCommandDescriptor {
  const CoreKeeneticCommandDescriptor({
    required this.target,
    required this.actions,
    required this.expectedUserRevision,
  });

  final CoreKeeneticCommandTarget target;
  final List<CoreKeeneticCommandAction> actions;
  final int expectedUserRevision;

  factory CoreKeeneticCommandDescriptor.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        !{'target', 'actions', 'expectedUserRevision'}.every(raw.containsKey)) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final rawTarget = raw['target'];
    if (rawTarget is! Map) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final target = CoreKeeneticCommandTarget.fromJson(
      Map<String, dynamic>.from(rawTarget),
    );
    final rawActions = raw['actions'];
    final revision = raw['expectedUserRevision'];
    if (rawActions is! List ||
        rawActions.length != 1 ||
        rawActions.single is! String ||
        revision is! int ||
        revision < 1 ||
        revision > 9223372036854775807) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final action = switch (rawActions.single) {
      'guest_wifi_enable' => CoreKeeneticCommandAction.guestWifiEnable,
      'guest_wifi_disable' => CoreKeeneticCommandAction.guestWifiDisable,
      'client_internet_pause' => CoreKeeneticCommandAction.clientInternetPause,
      'client_internet_resume' =>
        CoreKeeneticCommandAction.clientInternetResume,
      'wan_reconnect' => CoreKeeneticCommandAction.wanReconnect,
      _ => throw const CoreKeeneticCommandFailure('invalid_response'),
    };
    final valid = switch ((target.targetKind, target.value, action)) {
      ('guest_wifi', 'disabled', CoreKeeneticCommandAction.guestWifiEnable) ||
      ('guest_wifi', 'enabled', CoreKeeneticCommandAction.guestWifiDisable) ||
      ('client', 'allowed', CoreKeeneticCommandAction.clientInternetPause) ||
      ('client', 'paused', CoreKeeneticCommandAction.clientInternetResume) ||
      ('wan', 'online', CoreKeeneticCommandAction.wanReconnect) => true,
      _ => false,
    };
    if (!valid) throw const CoreKeeneticCommandFailure('invalid_response');
    return CoreKeeneticCommandDescriptor(
      target: target,
      actions: List.unmodifiable([action]),
      expectedUserRevision: revision,
    );
  }
}

class CoreKeeneticCommandPreview {
  const CoreKeeneticCommandPreview({
    required this.id,
    required this.confirmToken,
    required this.requestId,
    required this.action,
    required this.targetFingerprint,
    required this.highRisk,
  });
  final String id, confirmToken, requestId, targetFingerprint;
  final CoreKeeneticCommandAction action;
  final bool highRisk;
}

class CoreKeeneticConfirmation {
  const CoreKeeneticConfirmation(this.token);
  final String token;
}

class CoreKeeneticCommandReceipt {
  const CoreKeeneticCommandReceipt(this.status, this.code);
  final CoreKeeneticCommandStatus status;
  final String code;
}

sealed class CoreKeeneticConfirmResult {
  const CoreKeeneticConfirmResult();
}

class CoreKeeneticNeedsConfirmation extends CoreKeeneticConfirmResult {
  const CoreKeeneticNeedsConfirmation(this.confirmation);
  final CoreKeeneticConfirmation confirmation;
}

class CoreKeeneticFinished extends CoreKeeneticConfirmResult {
  const CoreKeeneticFinished(this.receipt);
  final CoreKeeneticCommandReceipt receipt;
}

abstract interface class CoreKeeneticCommandApi {
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  );
  Future<CoreKeeneticConfirmResult> confirm(String previewId, String token);
  Future<CoreKeeneticCommandReceipt> cancel(String previewId);
  Future<CoreKeeneticCommandReceipt> status(String requestId);
}

class HttpCoreKeeneticCommandAuthority {
  HttpCoreKeeneticCommandAuthority({
    required this.server,
    required this.accessToken,
    required this.coreId,
    required this.homeId,
    required this.resourceId,
  }) {
    for (final value in [coreId, homeId, resourceId]) {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw const CoreKeeneticCommandFailure('invalid_request');
      }
    }
  }

  final LarenorServerApi server;
  final String accessToken, coreId, homeId, resourceId;
  Map<String, CoreKeeneticCommandDescriptor> _current = const {};

  String get _root =>
      '/admin/homes/$coreId/$homeId/resources/$resourceId/keenetic/commands';

  Future<List<CoreKeeneticCommandDescriptor>> targets() async {
    _current = const {};
    final raw = await server.request(
      'GET',
      '$_root/targets',
      token: accessToken,
    );
    if (raw == null || raw.length != 1 || raw['descriptors'] is! List) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final list = raw['descriptors'] as List;
    if (list.isEmpty || list.length > 128) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final result = list.map(CoreKeeneticCommandDescriptor.fromJson).toList();
    final fingerprints = result.map((item) => item.target.fingerprint).toSet();
    if (fingerprints.length != result.length ||
        result.any(
          (item) =>
              item.target.coreId != coreId ||
              item.target.homeId != homeId ||
              item.target.resourceId != resourceId,
        )) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    _current = {for (final item in result) item.target.fingerprint: item};
    return List.unmodifiable(result);
  }

  HttpCoreKeeneticCommandApi apiFor(CoreKeeneticCommandDescriptor descriptor) {
    final current = _current[descriptor.target.fingerprint];
    if (!identical(current, descriptor)) {
      throw const CoreKeeneticCommandFailure('invalid_request');
    }
    return HttpCoreKeeneticCommandApi(
      server: server,
      accessToken: accessToken,
      expectedUserRevision: descriptor.expectedUserRevision,
    );
  }
}

class UnavailableCoreKeeneticCommandApi implements CoreKeeneticCommandApi {
  const UnavailableCoreKeeneticCommandApi();

  @override
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  ) => Future.error(const CoreKeeneticCommandFailure('effect_unavailable'));

  @override
  Future<CoreKeeneticConfirmResult> confirm(String previewId, String token) =>
      Future.error(const CoreKeeneticCommandFailure('effect_unavailable'));

  @override
  Future<CoreKeeneticCommandReceipt> cancel(String previewId) async =>
      const CoreKeeneticCommandReceipt(
        CoreKeeneticCommandStatus.cancelled,
        'cancelled',
      );

  @override
  Future<CoreKeeneticCommandReceipt> status(String requestId) =>
      Future.error(const CoreKeeneticCommandFailure('effect_unavailable'));
}

class HttpCoreKeeneticCommandApi implements CoreKeeneticCommandApi {
  HttpCoreKeeneticCommandApi({
    required this.server,
    required this.accessToken,
    required this.expectedUserRevision,
    Random? random,
  }) : _random = random ?? Random.secure();

  final LarenorServerApi server;
  final String accessToken;
  final int expectedUserRevision;
  final Random _random;
  CoreKeeneticCommandTarget? _target;

  String _hex(int count) => List.generate(
    count,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String _key() =>
      base64UrlEncode(List.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  String _root(CoreKeeneticCommandTarget target) =>
      '/admin/homes/${target.coreId}/${target.homeId}/resources/'
      '${target.resourceId}/keenetic/commands';

  static String _action(CoreKeeneticCommandAction value) => switch (value) {
    CoreKeeneticCommandAction.guestWifiEnable => 'guest_wifi_enable',
    CoreKeeneticCommandAction.guestWifiDisable => 'guest_wifi_disable',
    CoreKeeneticCommandAction.clientInternetPause => 'client_internet_pause',
    CoreKeeneticCommandAction.clientInternetResume => 'client_internet_resume',
    CoreKeeneticCommandAction.wanReconnect => 'wan_reconnect',
  };

  @override
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  ) async {
    _target = target;
    final result = await server.request(
      'POST',
      '${_root(target)}/preview',
      token: accessToken,
      body: {
        'schemaVersion': 1,
        'action': _action(action),
        'target': target.toJson(),
        'expectedUserRevision': expectedUserRevision,
        'requestId': _hex(16),
        'idempotencyKey': _key(),
        'reason': 'Explicit Android tablet command',
      },
    );
    if (result == null || result.length != 1 || result['preview'] is! Map) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final value = Map<String, dynamic>.from(result['preview'] as Map);
    if (value.length != 8 ||
        value['status'] != 'accepted' ||
        value['action'] != _action(action) ||
        CoreKeeneticCommandTarget.fromJson(value['target']).fingerprint !=
            target.fingerprint) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    String exact(String key, RegExp pattern) {
      final item = value[key];
      if (item is! String || !pattern.hasMatch(item)) {
        throw const CoreKeeneticCommandFailure('invalid_response');
      }
      return item;
    }

    final risk = value['risk'];
    if (!{'low', 'medium', 'high'}.contains(risk) ||
        value['expiresInMs'] is! int ||
        (value['expiresInMs'] as int) < 1 ||
        (value['expiresInMs'] as int) > 60000) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    return CoreKeeneticCommandPreview(
      id: exact('id', RegExp(r'^[0-9a-f]{32}$')),
      confirmToken: exact('confirmToken', RegExp(r'^[A-Za-z0-9_-]{43}$')),
      requestId: exact('requestId', RegExp(r'^[0-9a-f]{32}$')),
      action: action,
      targetFingerprint: target.fingerprint,
      highRisk: risk == 'high',
    );
  }

  @override
  Future<CoreKeeneticConfirmResult> confirm(
    String previewId,
    String token,
  ) async {
    final target = _target;
    if (target == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(previewId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const CoreKeeneticCommandFailure('invalid_request');
    }
    final result = await server.request(
      'POST',
      '${_root(target)}/$previewId/confirm',
      token: accessToken,
      body: {'token': token},
    );
    return parseConfirmForTest(result);
  }

  CoreKeeneticConfirmResult parseConfirmForTest(Object? raw) {
    if (raw is! Map<String, dynamic> || raw.length != 1) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    if (raw['confirmation'] case final Map confirmation) {
      if (confirmation.length != 3 ||
          confirmation['risk'] != 'high' ||
          confirmation['token'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$')
              .hasMatch(confirmation['token'] as String) ||
          confirmation['expiresInMs'] is! int) {
        throw const CoreKeeneticCommandFailure('invalid_response');
      }
      return CoreKeeneticNeedsConfirmation(
        CoreKeeneticConfirmation(confirmation['token'] as String),
      );
    }
    return CoreKeeneticFinished(_receipt(raw['receipt']));
  }

  CoreKeeneticCommandReceipt _receipt(Object? raw) {
    if (raw is! Map ||
        raw.length != 6 ||
        raw['code'] is! String ||
        raw['transitions'] is! List ||
        raw['requestId'] is! String ||
        raw['action'] is! String ||
        raw['target'] is! Map) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    CoreKeeneticCommandTarget.fromJson(
      Map<String, dynamic>.from(raw['target'] as Map),
    );
    final status = switch (raw['status']) {
      'succeeded' => CoreKeeneticCommandStatus.succeeded,
      'failed' => CoreKeeneticCommandStatus.failed,
      'cancelled' => CoreKeeneticCommandStatus.cancelled,
      'unknown' => CoreKeeneticCommandStatus.unknown,
      _ => throw const CoreKeeneticCommandFailure('invalid_response'),
    };
    return CoreKeeneticCommandReceipt(status, raw['code'] as String);
  }

  @override
  Future<CoreKeeneticCommandReceipt> cancel(String previewId) async {
    final target = _target;
    if (target == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(previewId)) {
      throw const CoreKeeneticCommandFailure('invalid_request');
    }
    final result = await server.request(
      'POST',
      '${_root(target)}/$previewId/cancel',
      token: accessToken,
    );
    return switch (parseConfirmForTest(result)) {
      CoreKeeneticFinished(:final receipt) => receipt,
      _ => throw const CoreKeeneticCommandFailure('invalid_response'),
    };
  }

  @override
  Future<CoreKeeneticCommandReceipt> status(String requestId) async {
    final target = _target;
    if (target == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const CoreKeeneticCommandFailure('invalid_request');
    }
    final result = await server.request(
      'GET',
      '${_root(target)}/status/$requestId',
      token: accessToken,
    );
    if (result == null || result.length != 1 || result['command'] is! Map) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final command = Map<String, dynamic>.from(result['command'] as Map);
    if (command.length != 6 ||
        command['status'] is! String ||
        command['action'] is! String ||
        command['target'] is! Map ||
        command['requestId'] != requestId) {
      throw const CoreKeeneticCommandFailure('invalid_response');
    }
    final status = switch (command['status']) {
      'succeeded' => CoreKeeneticCommandStatus.succeeded,
      'failed' => CoreKeeneticCommandStatus.failed,
      'cancelled' => CoreKeeneticCommandStatus.cancelled,
      'unknown' => CoreKeeneticCommandStatus.unknown,
      _ => throw const CoreKeeneticCommandFailure('pending'),
    };
    return CoreKeeneticCommandReceipt(status, command['status'] as String);
  }
}

class CoreKeeneticCommandAuthorityScreen extends StatefulWidget {
  const CoreKeeneticCommandAuthorityScreen({
    super.key,
    required this.authority,
    required this.isCurrent,
  });

  final HttpCoreKeeneticCommandAuthority authority;
  final bool Function() isCurrent;

  @override
  State<CoreKeeneticCommandAuthorityScreen> createState() =>
      _CoreKeeneticCommandAuthorityScreenState();
}

class _CoreKeeneticCommandAuthorityScreenState
    extends State<CoreKeeneticCommandAuthorityScreen>
    with WidgetsBindingObserver {
  List<CoreKeeneticCommandDescriptor>? _targets;
  String? _error;
  int _generation = 0;
  bool _busy = false, _retired = false;

  bool _current(int generation) =>
      mounted && !_retired && generation == _generation && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _retire();
  }

  void _retire({bool notify = true}) {
    if (_retired) return;
    _retired = true;
    _generation++;
    widget.authority.server.close();
    if (notify && mounted) {
      setState(() {
        _targets = null;
        _busy = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (_busy || _retired || !widget.isCurrent()) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _targets = null;
    });
    try {
      final value = await widget.authority.targets();
      if (!_current(generation)) return;
      setState(() {
        _targets = value;
        _busy = false;
      });
    } catch (error) {
      if (!_current(generation)) return;
      setState(() {
        _busy = false;
        _error = error is CoreKeeneticCommandFailure ? error.code : 'failed';
      });
    }
  }

  String _title(CoreKeeneticCommandTarget target, AppLocalizations l10n) =>
      switch (target.targetKind) {
        'guest_wifi' => l10n.keeneticCommandGuestWifi,
        'client' => l10n.keeneticCommandClient,
        _ => l10n.keeneticCommandWan,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.keeneticCommandTitle),
        trailing: CupertinoButton(
          key: const ValueKey('keenetic-command-refresh'),
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(48),
          onPressed: _busy || _retired ? null : _refresh,
          child: Semantics(
            button: true,
            label: l10n.commonRefresh,
            child: const Icon(CupertinoIcons.refresh),
          ),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoListTile(
                      title: Text(l10n.keeneticCommandUnavailable),
                    ),
                  ],
                ),
              ),
            if (_targets case final targets?)
              CupertinoListSection.insetGrouped(
                children: [
                  for (final descriptor in targets)
                    SettingsActionTile(
                      title: Text(_title(descriptor.target, l10n)),
                      additionalInfo: Text(descriptor.target.targetId),
                      onTap: _retired || !widget.isCurrent()
                          ? null
                          : () {
                              final fingerprint = descriptor.target.fingerprint;
                              Navigator.of(context).push<void>(
                                CupertinoPageRoute(
                                  builder: (_) => CoreKeeneticCommandPanel(
                                    target: descriptor.target,
                                    isAdmin: true,
                                    canWrite:
                                        descriptor.target.fingerprint ==
                                        fingerprint,
                                    isCurrent: widget.isCurrent,
                                    api: widget.authority.apiFor(descriptor),
                                  ),
                                ),
                              );
                            },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retire(notify: false);
    super.dispose();
  }
}

class CoreKeeneticCommandPanel extends StatefulWidget {
  const CoreKeeneticCommandPanel({
    super.key,
    required this.target,
    required this.isAdmin,
    required this.canWrite,
    this.isCurrent,
    this.api = const UnavailableCoreKeeneticCommandApi(),
  });

  final CoreKeeneticCommandTarget target;
  final bool isAdmin, canWrite;
  final bool Function()? isCurrent;
  final CoreKeeneticCommandApi api;

  @override
  State<CoreKeeneticCommandPanel> createState() =>
      _CoreKeeneticCommandPanelState();
}

class _CoreKeeneticCommandPanelState extends State<CoreKeeneticCommandPanel>
    with WidgetsBindingObserver {
  CoreKeeneticCommandPreview? _preview;
  CoreKeeneticCommandApi? _previewOwner;
  CoreKeeneticConfirmation? _second;
  CoreKeeneticCommandReceipt? _receipt;
  String? _error;
  int _generation = 0;
  bool _busy = false, _retired = false;

  bool get _authorityCurrent {
    try {
      return widget.isCurrent?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  bool _current(int generation) =>
      mounted &&
      !_retired &&
      generation == _generation &&
      widget.isAdmin &&
      widget.canWrite &&
      _authorityCurrent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant CoreKeeneticCommandPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.fingerprint != widget.target.fingerprint ||
        oldWidget.api != widget.api ||
        oldWidget.isAdmin != widget.isAdmin ||
        oldWidget.canWrite != widget.canWrite ||
        !_authorityCurrent) {
      _retire(cancelPreview: _authorityCurrent);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _retire();
  }

  void _retire({bool notify = true, bool cancelPreview = true}) {
    if (_retired) return;
    _retired = true;
    _generation++;
    final preview = _preview;
    final previewOwner = _previewOwner;
    _preview = null;
    _previewOwner = null;
    _second = null;
    _receipt = null;
    _busy = false;
    if (preview != null &&
        previewOwner != null &&
        cancelPreview &&
        _authorityCurrent) {
      unawaited(previewOwner.cancel(preview.id));
    }
    if (notify && mounted) setState(() {});
  }

  Future<void> _begin(CoreKeeneticCommandAction action) async {
    if (_busy ||
        _retired ||
        !widget.isAdmin ||
        !widget.canWrite ||
        !_authorityCurrent) {
      return;
    }
    final generation = ++_generation;
    final previewOwner = widget.api;
    setState(() {
      _busy = true;
      _error = null;
      _receipt = null;
    });
    try {
      final preview = await previewOwner.preview(action, widget.target);
      if (!_current(generation) ||
          preview.targetFingerprint != widget.target.fingerprint) {
        if (_authorityCurrent) unawaited(previewOwner.cancel(preview.id));
        return;
      }
      setState(() {
        _preview = preview;
        _previewOwner = previewOwner;
        _busy = false;
      });
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _busy = false;
          _error = error is CoreKeeneticCommandFailure ? error.code : 'failed';
        });
      }
    }
  }

  Future<void> _confirm() async {
    final preview = _preview;
    final previewOwner = _previewOwner;
    if (preview == null ||
        previewOwner == null ||
        _busy ||
        _retired ||
        !_authorityCurrent) {
      return;
    }
    final generation = _generation;
    final token = _second?.token ?? preview.confirmToken;
    setState(() => _busy = true);
    try {
      final result = await previewOwner.confirm(preview.id, token);
      if (!_current(generation)) return;
      setState(() {
        _busy = false;
        if (result is CoreKeeneticNeedsConfirmation) {
          _second = result.confirmation;
        } else if (result is CoreKeeneticFinished) {
          _receipt = result.receipt;
          _preview = null;
          _previewOwner = null;
          _second = null;
        }
      });
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _busy = false;
          _preview = null;
          _previewOwner = null;
          _second = null;
          _error = error is CoreKeeneticCommandFailure ? error.code : 'failed';
        });
      }
    }
  }

  Future<void> _cancel() async {
    final preview = _preview;
    final previewOwner = _previewOwner;
    if (preview == null ||
        previewOwner == null ||
        _busy ||
        _retired ||
        !_authorityCurrent) {
      return;
    }
    _generation++;
    setState(() {
      _preview = null;
      _previewOwner = null;
      _second = null;
      _busy = false;
    });
    try {
      await previewOwner.cancel(preview.id);
    } catch (_) {
      // A cancel result cannot make a command executable or successful.
    }
  }

  String _title(AppLocalizations l10n) => switch (widget.target.targetKind) {
    'guest_wifi' => l10n.keeneticCommandGuestWifi,
    'client' => l10n.keeneticCommandClient,
    _ => l10n.keeneticCommandWan,
  };

  List<(String, CoreKeeneticCommandAction)> _actions(
    AppLocalizations l10n,
  ) => switch ((widget.target.targetKind, widget.target.value)) {
    ('guest_wifi', 'disabled') => [
      (l10n.keeneticCommandEnable, CoreKeeneticCommandAction.guestWifiEnable),
    ],
    ('guest_wifi', 'enabled') => [
      (l10n.keeneticCommandDisable, CoreKeeneticCommandAction.guestWifiDisable),
    ],
    ('client', 'allowed') => [
      (
        l10n.keeneticCommandPause,
        CoreKeeneticCommandAction.clientInternetPause,
      ),
    ],
    ('client', 'paused') => [
      (
        l10n.keeneticCommandResume,
        CoreKeeneticCommandAction.clientInternetResume,
      ),
    ],
    ('wan', _) => [
      (l10n.keeneticCommandReconnect, CoreKeeneticCommandAction.wanReconnect),
    ],
    _ => const [],
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canAct =
        widget.isAdmin && widget.canWrite && !_retired && _authorityCurrent;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.keeneticCommandTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: CoreInfrastructureEvidenceStatus(
                surface: 'keenetic-operation',
                evidence: coreInfrastructureOperationEvidence(
                  pending: _busy,
                  succeeded:
                      _receipt?.status == CoreKeeneticCommandStatus.succeeded,
                  unknown:
                      _receipt?.status == CoreKeeneticCommandStatus.unknown,
                  failed:
                      _error != null ||
                      _receipt?.status == CoreKeeneticCommandStatus.failed,
                ),
                showTimestamp: false,
              ),
            ),
            CupertinoListSection.insetGrouped(
              header: Text(_title(l10n)),
              children: [
                CupertinoListTile(
                  title: Text(widget.target.targetId),
                  additionalInfo: Text(widget.target.value),
                ),
                if (!canAct)
                  CupertinoListTile(title: Text(l10n.keeneticCommandReadOnly)),
                if (canAct && _preview == null)
                  for (final action in _actions(l10n))
                    SettingsActionTile(
                      title: Text(action.$1),
                      onTap: _busy ? null : () => _begin(action.$2),
                    ),
              ],
            ),
            if (_preview != null && canAct)
              CupertinoListSection.insetGrouped(
                header: Text(
                  _second == null
                      ? l10n.keeneticCommandReview
                      : l10n.keeneticCommandWanConfirmAgain,
                ),
                children: [
                  SettingsActionTile(
                    title: Text(
                      _second == null
                          ? l10n.keeneticCommandConfirm
                          : l10n.keeneticCommandConfirmAgain,
                    ),
                    onTap: _busy ? null : _confirm,
                  ),
                  SettingsActionTile(
                    title: Text(l10n.keeneticCommandCancel),
                    onTap: _busy ? null : _cancel,
                  ),
                ],
              ),
            if (_receipt != null || _error != null)
              Semantics(
                liveRegion: true,
                child: CupertinoListSection.insetGrouped(
                  children: [CupertinoListTile(title: Text(_resultText(l10n)))],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _resultText(AppLocalizations l10n) {
    if (_error == 'effect_unavailable') return l10n.keeneticCommandUnavailable;
    return switch (_receipt?.status) {
      CoreKeeneticCommandStatus.succeeded => l10n.keeneticCommandSucceeded,
      CoreKeeneticCommandStatus.unknown => l10n.keeneticCommandUnknown,
      _ => l10n.keeneticCommandFailed,
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retire(notify: false);
    super.dispose();
  }
}
