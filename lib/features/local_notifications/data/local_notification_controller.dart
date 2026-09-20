import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/local_notification_models.dart';
import 'local_notification_api.dart';
import 'local_notification_store.dart';

typedef LocalNotificationApiFactory = LarenorServerApi Function(
  ServerEndpoint endpoint,
);

abstract interface class LocalNotificationPermissionGateway {
  Future<LocalNotificationPermission> read();
}

final class InAppNotificationPermissionGateway
    implements LocalNotificationPermissionGateway {
  @override
  Future<LocalNotificationPermission> read() async =>
      LocalNotificationPermission.inAppOnly;
}

class LocalNotificationController extends ChangeNotifier {
  LocalNotificationController({
    required this.home,
    required this.apiFactory,
    required this.store,
    required this.permissionGateway,
    required this.clock,
    required this.windowCurrent,
    required this.owner,
  }) {
    home.addListener(_authorityChanged);
    home.account.addListener(_authorityChanged);
    home.interaction.addListener(_authorityChanged);
    owner.addListener(_authorityChanged);
  }

  final HomeSessionController home;
  final LocalNotificationApiFactory apiFactory;
  final LocalNotificationStore store;
  final LocalNotificationPermissionGateway permissionGateway;
  final DateTime Function() clock;
  final bool Function() windowCurrent;
  final Listenable owner;
  bool _disposed = false, _visible = false;
  int epoch = 0;
  bool busy = false, loaded = false;
  String? failure;
  LocalNotificationPermission permission = LocalNotificationPermission.denied;
  LocalNotificationSubscription? subscription;
  List<LocalNotificationEvent> events = const [];
  int? nextAfter;
  LarenorServerApi? _transport;

  ServerSession? get _ready {
    final session = home.account.session;
    if (_disposed ||
        !_visible ||
        !windowCurrent() ||
        owner is LocalNotificationOwner &&
            !(owner as LocalNotificationOwner).isCurrent ||
        home.source != HomeSource.verifiedCore ||
        home.busy ||
        home.failure != null ||
        !home.interaction.active ||
        !home.account.initialized ||
        home.account.working ||
        home.account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        session.expiresSoon(clock())) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && subscription != null;
  bool get canRefresh => _ready != null && !busy;
  bool get canLoadMore => fresh && !busy && nextAfter != null;

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _retire(clear: true);
    if (value) {
      unawaited(refresh());
    }
  }

  void _authorityChanged() {
    if (_disposed) return;
    if (_ready == null) {
      _retire(clear: true);
    }
    notifyListeners();
  }

  void _retire({required bool clear}) {
    epoch++;
    busy = false;
    _transport?.close();
    _transport = null;
    failure = null;
    if (clear) {
      loaded = false;
      subscription = null;
      events = const [];
      nextAfter = null;
      permission = LocalNotificationPermission.denied;
    }
  }

  bool _same(
    ServerSession original,
    int generation,
    int interactionEpoch,
    int operation,
  ) {
    final current = _ready;
    return !_disposed &&
        epoch == operation &&
        current != null &&
        home.account.isCurrent(generation) &&
        home.interaction.epoch == interactionEpoch &&
        identical(current, original) &&
        current.context == original.context &&
        current.user.id == original.user.id &&
        current.endpoint.baseUrl == original.endpoint.baseUrl;
  }

  Future<LocalNotificationSubscription> _bind(
    LocalNotificationApi api,
    ServerSession session,
    LocalNotificationStoredSubscription? stored,
    bool Function() current,
  ) async {
    final context = session.context!,
        actor = session.user.id,
        now = clock().toUtc();
    var record = stored;
    if (record == null) {
      record = LocalNotificationStore.create(context, actor, now);
      await store.write(record, before: null, isCurrent: current);
    }
    Future<LocalNotificationSubscription> attempt(
      LocalNotificationStoredSubscription value,
    ) async {
      if (value.revision == 0) {
        return api.register(id: value.id, expiresAt: value.expiresAt);
      }
      final before = LocalNotificationSubscription(
        id: value.id,
        revision: value.revision,
        permission: LocalNotificationPermission.inAppOnly,
        expiresAt: value.expiresAt,
      );
      return value.expiresAt.isBefore(now.add(const Duration(days: 1)))
          ? api.renew(before, expiresAt: now.add(const Duration(days: 30)))
          : api.register(id: value.id, expiresAt: value.expiresAt);
    }

    LocalNotificationSubscription bound;
    try {
      bound = await attempt(record);
    } on LarenorServerException catch (error) {
      if (error.code != 'not_found' &&
          error.code != 'notification_registration_replay') {
        rethrow;
      }
      final replacement = LocalNotificationStore.create(context, actor, now);
      await store.write(replacement, before: record, isCurrent: current);
      record = replacement;
      bound = await attempt(record);
    }
    final saved = LocalNotificationStoredSubscription(
      context: context,
      actorId: actor,
      id: bound.id,
      revision: bound.revision,
      expiresAt: bound.expiresAt,
    );
    if (saved.revision != record.revision ||
        saved.expiresAt != record.expiresAt) {
      await store.write(saved, before: record, isCurrent: current);
    }
    return bound;
  }

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);
  Future<void> _load({required bool more}) async {
    final original = _ready;
    if (original == null || busy || (more && !canLoadMore)) return;
    final generation = home.account.generation,
        interactionEpoch = home.interaction.epoch,
        operation = ++epoch;
    bool current() => _same(original, generation, interactionEpoch, operation);
    busy = true;
    failure = null;
    if (!more) {
      loaded = false;
      events = const [];
      nextAfter = null;
    }
    notifyListeners();
    try {
      permission = await permissionGateway.read();
      if (!current()) return;
      if (permission == LocalNotificationPermission.denied) {
        throw const LarenorServerException('permission_denied');
      }
      final stored = await store.read(
        original.context!,
        original.user.id,
        isCurrent: current,
      );
      if (!current()) return;
      _transport = apiFactory(original.endpoint);
      final api = LocalNotificationApi(
        _transport!,
        original,
        isCurrent: current,
      );
      final bound = more
          ? subscription!
          : await _bind(api, original, stored, current);
      if (!current()) return;
      final page = await api.pull(bound, after: more ? nextAfter ?? 0 : 0);
      if (!current()) return;
      final merged = <int, LocalNotificationEvent>{
        for (final event in more ? events : const <LocalNotificationEvent>[])
          event.sequence: event,
      };
      for (final event in page.events) {
        final before = merged[event.sequence];
        if (before != null && !before.sameEnvelope(event)) {
          throw const LarenorServerException('invalid_response');
        }
        merged[event.sequence] =
            before?.readState == LocalNotificationReadState.read
            ? event.asRead()
            : event;
      }
      final ordered = merged.values.toList()
        ..sort((a, b) => b.sequence.compareTo(a.sequence));
      subscription = bound;
      events = List.unmodifiable(ordered);
      nextAfter = page.nextAfter;
      loaded = true;
    } catch (error) {
      if (current()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        if (!more) {
          subscription = null;
          events = const [];
          loaded = false;
        }
      }
    } finally {
      if (!_disposed && epoch == operation) {
        _transport?.close();
        _transport = null;
        busy = false;
        if (!current()) {
          subscription = null;
          events = const [];
          loaded = false;
          failure = null;
        }
        notifyListeners();
      }
    }
  }

  Future<bool> markRead(
    LocalNotificationEvent target, {
    required bool Function() interactionCurrent,
  }) async {
    final original = _ready, bound = subscription;
    if (original == null ||
        bound == null ||
        busy ||
        target.readState == LocalNotificationReadState.read ||
        !events.any((event) => identical(event, target)) ||
        !interactionCurrent()) {
      return false;
    }
    final generation = home.account.generation,
        interactionEpoch = home.interaction.epoch,
        operation = ++epoch;
    bool current() {
      try {
        return interactionCurrent() &&
            _same(original, generation, interactionEpoch, operation);
      } catch (_) {
        return false;
      }
    }

    busy = true;
    failure = null;
    notifyListeners();
    try {
      _transport = apiFactory(original.endpoint);
      await LocalNotificationApi(
        _transport!,
        original,
        isCurrent: current,
      ).acknowledge(bound, target);
      if (!current()) return false;
      events = List.unmodifiable(
        events.map(
          (event) => identical(event, target) ? event.asRead() : event,
        ),
      );
      return true;
    } catch (error) {
      if (current()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
      return false;
    } finally {
      if (!_disposed && epoch == operation) {
        _transport?.close();
        _transport = null;
        busy = false;
        if (!current()) {
          failure = null;
        }
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retire(clear: true);
    home.removeListener(_authorityChanged);
    home.account.removeListener(_authorityChanged);
    home.interaction.removeListener(_authorityChanged);
    owner.removeListener(_authorityChanged);
    super.dispose();
  }
}

abstract interface class LocalNotificationOwner implements Listenable {
  bool get isCurrent;
}
