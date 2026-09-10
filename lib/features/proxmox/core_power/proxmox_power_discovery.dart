import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import 'proxmox_power_models.dart';

enum ProxmoxTargetDiscoveryPhase {
  idle,
  loading,
  ready,
  ambiguous,
  stale,
  offline,
  unavailable,
  forbidden,
  invalid,
}

Never _invalid([String code = 'invalid_response']) =>
    throw LarenorServerException(code);

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _hex(Object? value, int length) {
  if (value is! String ||
      value.length != length ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

final class ProxmoxTargetDiscoveryResult {
  const ProxmoxTargetDiscoveryResult._(this.phase, this.target);

  factory ProxmoxTargetDiscoveryResult.fromJson(
    Object? raw, {
    required HomeResourceRecord expectedResource,
  }) {
    final page = _object(raw, {
      'schemaVersion',
      'scope',
      'resourceId',
      'userRevision',
      'resourceRevision',
      'aclRevision',
      'bindingId',
      'bindingRevision',
      'serviceId',
      'serviceRevision',
      'snapshot',
      'targets',
      'nextAfter',
    });
    if (page['schemaVersion'] != 1) _invalid();
    final scope = ServerContext.fromJson(page['scope']);
    final resourceId = _hex(page['resourceId'], 32);
    final resourceRevision = _integer(
      page['resourceRevision'],
      1,
      9223372036854775807,
    );
    final aclRevision = _integer(page['aclRevision'], 1, 9223372036854775807);
    if (scope != expectedResource.context ||
        resourceId != expectedResource.id ||
        resourceRevision != expectedResource.revision ||
        aclRevision != expectedResource.aclRevision) {
      _invalid('revision_conflict');
    }
    final userRevision = _integer(page['userRevision'], 1, 9223372036854775807);
    final bindingId = _hex(page['bindingId'], 32);
    final bindingRevision = _integer(
      page['bindingRevision'],
      1,
      9223372036854775807,
    );
    final serviceId = _hex(page['serviceId'], 32);
    final serviceRevision = _integer(
      page['serviceRevision'],
      1,
      9223372036854775807,
    );
    _hex(page['snapshot'], 64);
    final rawTargets = page['targets'];
    if (rawTargets is! List || rawTargets.length > 2) _invalid();
    final targets = <_DiscoveredTarget>[];
    var previous = '';
    for (final rawTarget in rawTargets) {
      final value = _DiscoveredTarget.fromJson(rawTarget);
      if (value.targetId.compareTo(previous) <= 0 ||
          value.installationId != serviceId) {
        _invalid();
      }
      targets.add(value);
      previous = value.targetId;
    }
    final nextAfter = page['nextAfter'] == null
        ? null
        : _hex(page['nextAfter'], 32);
    if (nextAfter != null &&
        (targets.isEmpty || nextAfter != targets.last.targetId)) {
      _invalid();
    }
    if (targets.length != 1 || nextAfter != null) {
      return const ProxmoxTargetDiscoveryResult._(
        ProxmoxTargetDiscoveryPhase.ambiguous,
        null,
      );
    }
    final discovered = targets.single;
    if (!discovered.capabilityReady) {
      return const ProxmoxTargetDiscoveryResult._(
        ProxmoxTargetDiscoveryPhase.unavailable,
        null,
      );
    }
    final target = ProxmoxPowerTarget(
      coreId: scope.coreId,
      homeId: scope.homeId,
      resourceId: resourceId,
      userRevision: userRevision,
      resourceRevision: resourceRevision,
      aclRevision: aclRevision,
      bindingId: bindingId,
      bindingRevision: bindingRevision,
      serviceId: serviceId,
      serviceRevision: serviceRevision,
      guestKind: discovered.guestKind,
      currentState: discovered.currentState!,
      statusRevision: discovered.statusRevision,
      allowedActions: Set.unmodifiable(discovered.allowedActions),
    );
    target.validate();
    return ProxmoxTargetDiscoveryResult._(
      ProxmoxTargetDiscoveryPhase.ready,
      target,
    );
  }

  final ProxmoxTargetDiscoveryPhase phase;
  final ProxmoxPowerTarget? target;
}

final class _DiscoveredTarget {
  const _DiscoveredTarget({
    required this.targetId,
    required this.installationId,
    required this.guestKind,
    required this.currentState,
    required this.statusRevision,
    required this.allowedActions,
    required this.capabilityReady,
  });

  factory _DiscoveredTarget.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'targetId',
      'installationId',
      'node',
      'guestKind',
      'guestId',
      'currentState',
      'statusRevision',
      'allowedCommands',
      'capabilityReady',
    });
    if (value['schemaVersion'] != 1 || value['capabilityReady'] is! bool) {
      _invalid();
    }
    final node = value['node'];
    if (node is! String ||
        !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$')
            .hasMatch(node)) {
      _invalid();
    }
    _integer(value['guestId'], 1, 999999999);
    final kind = switch (value['guestKind']) {
      'qemu' => ProxmoxGuestKind.qemu,
      'lxc' => ProxmoxGuestKind.lxc,
      _ => _invalid(),
    };
    final state = switch (value['currentState']) {
      'running' => ProxmoxGuestState.running,
      'stopped' => ProxmoxGuestState.stopped,
      'suspended' => ProxmoxGuestState.suspended,
      'unavailable' => null,
      _ => _invalid(),
    };
    final ready = value['capabilityReady'] as bool;
    final rawActions = value['allowedCommands'];
    if (rawActions is! List || rawActions.length > 6) _invalid();
    final actions = <ProxmoxPowerAction>[];
    for (final rawAction in rawActions) {
      final action = ProxmoxPowerAction.values
          .where((candidate) => candidate.name == rawAction)
          .firstOrNull;
      if (action == null || actions.contains(action)) _invalid();
      actions.add(action);
    }
    final expected = state == null
        ? const <ProxmoxPowerAction>[]
        : switch (state) {
            ProxmoxGuestState.running => const [
              ProxmoxPowerAction.shutdown,
              ProxmoxPowerAction.stop,
              ProxmoxPowerAction.reboot,
              ProxmoxPowerAction.suspend,
            ],
            ProxmoxGuestState.stopped => const [ProxmoxPowerAction.start],
            ProxmoxGuestState.suspended => const [ProxmoxPowerAction.resume],
          };
    if (!ready && actions.isNotEmpty ||
        ready && state == null ||
        ready &&
            (actions.length != expected.length ||
                !Iterable.generate(actions.length)
                    .every((index) => actions[index] == expected[index]))) {
      _invalid();
    }
    return _DiscoveredTarget(
      targetId: _hex(value['targetId'], 32),
      installationId: _hex(value['installationId'], 32),
      guestKind: kind,
      currentState: state,
      statusRevision: _integer(value['statusRevision'], 1, 9223372036854775807),
      allowedActions: List.unmodifiable(actions),
      capabilityReady: ready,
    );
  }

  final String targetId, installationId;
  final ProxmoxGuestKind guestKind;
  final ProxmoxGuestState? currentState;
  final int statusRevision;
  final List<ProxmoxPowerAction> allowedActions;
  final bool capabilityReady;
}

abstract interface class ProxmoxTargetDiscoveryGateway {
  Future<ProxmoxTargetDiscoveryResult> discover(HomeResourceRecord resource);
}

final class CoreProxmoxTargetDiscoveryApi
    implements ProxmoxTargetDiscoveryGateway {
  CoreProxmoxTargetDiscoveryApi(this.api, this.accessToken);
  final LarenorServerApi api;
  final String accessToken;

  @override
  Future<ProxmoxTargetDiscoveryResult> discover(
    HomeResourceRecord resource,
  ) async {
    try {
      final response = await api.request(
        'GET',
        '/admin/proxmox-power/${resource.context.coreId}/${resource.context.homeId}/${resource.id}/targets',
        token: accessToken,
        queryParameters: const {'limit': '2'},
      );
      return ProxmoxTargetDiscoveryResult.fromJson(
        response,
        expectedResource: resource,
      );
    } on LarenorServerException {
      rethrow;
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }
}

final class ProxmoxTargetDiscoveryController extends ChangeNotifier {
  ProxmoxTargetDiscoveryController({
    required this.gateway,
    required this.resource,
    required this.current,
  });
  final ProxmoxTargetDiscoveryGateway gateway;
  final HomeResourceRecord resource;
  final bool Function() current;
  int _epoch = 0;
  bool _disposed = false;
  ProxmoxTargetDiscoveryPhase phase = ProxmoxTargetDiscoveryPhase.idle;
  ProxmoxPowerTarget? target;

  bool get busy => phase == ProxmoxTargetDiscoveryPhase.loading;
  bool _valid(int operation) => !_disposed && current() && operation == _epoch;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> discover() async {
    if (_disposed || !current() || busy) return;
    final operation = ++_epoch;
    target = null;
    phase = ProxmoxTargetDiscoveryPhase.loading;
    _emit();
    try {
      final result = await gateway.discover(resource);
      if (!_valid(operation)) return;
      phase = result.phase;
      target = result.target;
    } on LarenorServerException catch (error) {
      if (!_valid(operation)) return;
      phase = switch (error.code) {
        'revision_conflict' || 'conflict' => ProxmoxTargetDiscoveryPhase.stale,
        'connection_failed' ||
        'timeout' ||
        'server_error' ||
        'rate_limited' => ProxmoxTargetDiscoveryPhase.offline,
        'forbidden' || 'unauthorized' => ProxmoxTargetDiscoveryPhase.forbidden,
        'not_found' => ProxmoxTargetDiscoveryPhase.unavailable,
        _ => ProxmoxTargetDiscoveryPhase.invalid,
      };
    } catch (_) {
      if (!_valid(operation)) return;
      phase = ProxmoxTargetDiscoveryPhase.invalid;
    }
    _emit();
  }

  void invalidate() {
    _epoch++;
    target = null;
    phase = ProxmoxTargetDiscoveryPhase.idle;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

final class ProxmoxTargetDiscoveryEntry extends StatefulWidget {
  const ProxmoxTargetDiscoveryEntry({
    super.key,
    required this.controller,
    required this.isAdmin,
    required this.canWrite,
    required this.onOpen,
  });
  final ProxmoxTargetDiscoveryController controller;
  final bool isAdmin, canWrite;
  final ValueChanged<ProxmoxPowerTarget> onOpen;

  @override
  State<ProxmoxTargetDiscoveryEntry> createState() =>
      _ProxmoxTargetDiscoveryEntryState();
}

final class _ProxmoxTargetDiscoveryEntryState
    extends State<ProxmoxTargetDiscoveryEntry>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    if (widget.isAdmin) unawaited(widget.controller.discover());
  }

  @override
  void didUpdateWidget(ProxmoxTargetDiscoveryEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      if (widget.isAdmin) unawaited(widget.controller.discover());
    } else if (!oldWidget.isAdmin && widget.isAdmin) {
      unawaited(widget.controller.discover());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.invalidate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final controller = widget.controller;
    final target = controller.target;
    final message = switch (controller.phase) {
      ProxmoxTargetDiscoveryPhase.idle =>
        tr ? 'Hedef doğrulaması bekliyor.' : 'Target verification is pending.',
      ProxmoxTargetDiscoveryPhase.loading =>
        tr
            ? 'Kesin güç hedefi doğrulanıyor…'
            : 'Verifying the exact power target…',
      ProxmoxTargetDiscoveryPhase.ready =>
        widget.canWrite
            ? (tr ? 'Güç hedefi hazır.' : 'Power target is ready.')
            : (tr ? 'Bu hedef salt okunur.' : 'This target is read-only.'),
      ProxmoxTargetDiscoveryPhase.ambiguous =>
        tr
            ? 'Birden fazla konuk bulundu; güç komutları kapalı.'
            : 'Multiple guests found; power commands are disabled.',
      ProxmoxTargetDiscoveryPhase.stale =>
        tr
            ? 'Hedef bilgisi değişti; açıkça yenileyin.'
            : 'Target details changed; refresh explicitly.',
      ProxmoxTargetDiscoveryPhase.offline =>
        tr
            ? 'Larenor Core veya Proxmox çevrimdışı.'
            : 'Larenor Core or Proxmox is offline.',
      ProxmoxTargetDiscoveryPhase.unavailable =>
        tr
            ? 'Komuta hazır bir Proxmox konuğu yok.'
            : 'No command-ready Proxmox guest is available.',
      ProxmoxTargetDiscoveryPhase.forbidden =>
        tr ? 'Yönetici yetkisi gerekli.' : 'Administrator access is required.',
      ProxmoxTargetDiscoveryPhase.invalid =>
        tr
            ? 'Hedef yanıtı doğrulanamadı.'
            : 'The target response could not be verified.',
    };
    final refreshable =
        !controller.busy &&
        controller.phase != ProxmoxTargetDiscoveryPhase.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            key: const ValueKey('core-proxmox-power-discovery-status'),
          ),
        ),
        const SizedBox(height: 8),
        if (target != null)
          Semantics(
            button: true,
            enabled: widget.canWrite,
            label: tr ? 'Güç denetimlerini aç' : 'Open power controls',
            excludeSemantics: true,
            child: CupertinoButton.tinted(
              key: const ValueKey('core-proxmox-power-open'),
              minimumSize: const Size.fromHeight(48),
              onPressed: widget.canWrite
                  ? () {
                      if (controller.current()) widget.onOpen(target);
                    }
                  : null,
              child: Text(tr ? 'Güç denetimlerini aç' : 'Open power controls'),
            ),
          ),
        if (refreshable)
          CupertinoButton(
            key: const ValueKey('core-proxmox-power-refresh'),
            minimumSize: const Size.fromHeight(48),
            onPressed: controller.current() ? controller.discover : null,
            child: Text(tr ? 'Hedefi yenile' : 'Refresh target'),
          ),
      ],
    );
  }
}

final class CoreProxmoxTargetDiscoveryEntry extends StatefulWidget {
  const CoreProxmoxTargetDiscoveryEntry({
    super.key,
    required this.api,
    required this.accessToken,
    required this.resource,
    required this.isAdmin,
    required this.current,
    required this.onOpen,
  });
  final LarenorServerApi api;
  final String accessToken;
  final HomeResourceRecord resource;
  final bool isAdmin;
  final bool Function() current;
  final ValueChanged<ProxmoxPowerTarget> onOpen;

  @override
  State<CoreProxmoxTargetDiscoveryEntry> createState() =>
      _CoreProxmoxTargetDiscoveryEntryState();
}

final class _CoreProxmoxTargetDiscoveryEntryState
    extends State<CoreProxmoxTargetDiscoveryEntry> {
  late ProxmoxTargetDiscoveryController _controller = _create();

  ProxmoxTargetDiscoveryController _create() =>
      ProxmoxTargetDiscoveryController(
        gateway: CoreProxmoxTargetDiscoveryApi(widget.api, widget.accessToken),
        resource: widget.resource,
        current: widget.current,
      );

  @override
  void didUpdateWidget(CoreProxmoxTargetDiscoveryEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.accessToken != widget.accessToken ||
        oldWidget.resource != widget.resource ||
        oldWidget.current != widget.current) {
      _controller.dispose();
      _controller = _create();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProxmoxTargetDiscoveryEntry(
    controller: _controller,
    isAdmin: widget.isAdmin,
    canWrite: widget.resource.canWrite,
    onOpen: widget.onOpen,
  );
}
