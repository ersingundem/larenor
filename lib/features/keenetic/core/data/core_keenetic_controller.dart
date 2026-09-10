import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/data/server_account_controller.dart';
import '../../../server/domain/server_models.dart';
import '../../../server/services/domain/server_service_models.dart';
import '../domain/core_keenetic_models.dart';
import 'core_keenetic_api.dart';

/// One selected Core resource and one mounted owner. No Direct fallback or retry.
class CoreKeeneticController extends ChangeNotifier {
  CoreKeeneticController(
    this.home,
    this.target,
    this.factory,
    this.clock,
    this.current,
    this.owner, {
    required this.admin,
  }) {
    home?.addListener(_changed);
    home?.interaction.addListener(_changed);
    home?.account.addListener(_changed);
    owner.addListener(_changed);
  }
  final HomeSessionController? home;
  final HomeResourceRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() current;
  final Listenable owner;
  final bool admin;
  int epoch = 0;
  bool busy = false, loaded = false, stale = false, saved = false;
  String? failure;
  HomeResourceRecord? record;
  CoreKeeneticSnapshot? snapshot;
  CoreKeeneticDetailsPage? details;
  CoreKeeneticBinding? binding;
  CoreKeeneticPreview? preview;
  List<ServerService> services = const [];
  bool _disposed = false, _visible = false, _attempted = false;
  Timer? _ttl;

  bool get _sourceCurrent {
    try {
      return !_disposed &&
          _visible &&
          current() &&
          home != null &&
          home!.source == HomeSource.verifiedCore &&
          !home!.busy &&
          home!.failure == null &&
          home!.interaction.active;
    } catch (_) {
      return false;
    }
  }

  ServerSession? get _ready {
    final account = home?.account, session = account?.session;
    if (!_sourceCurrent ||
        account == null ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context != target.context ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        admin && !session.user.canAdminister) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => _ready != null && !busy;
  bool get canPreview =>
      admin &&
      fresh &&
      loaded &&
      !busy &&
      preview == null &&
      services.any(
        (s) =>
            s.verification.state ==
            ServerServiceVerificationState.authenticated,
      );
  bool get canConfirm => admin && fresh && !busy && preview != null && !stale;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    _ttl?.cancel();
    _ttl = null;
    record = null;
    snapshot = null;
    details = null;
    binding = null;
    preview = null;
    services = const [];
    loaded = false;
    stale = false;
    saved = false;
  }

  void _retire() {
    epoch++;
    busy = false;
    failure = null;
    _clear();
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _retire();
    _attempted = false;
    _emit();
    _start();
  }

  void _start() {
    if (!_attempted && fresh) {
      _attempted = true;
      unawaited(refresh());
    }
  }

  void _changed() {
    if (_disposed) return;
    if (!fresh) {
      _retire();
      _attempted = false;
    }
    _emit();
    _start();
  }

  void _arm(int milliseconds) {
    _ttl?.cancel();
    _ttl = Timer(Duration(milliseconds: milliseconds), () {
      if (_disposed) return;
      snapshot = null;
      preview = null;
      stale = true;
      epoch++;
      _emit();
    });
  }

  Future<void> _run(
    Future<void> Function(CoreKeeneticApi Function(HomeResourceRecord)) action,
  ) async {
    final original = _ready;
    if (original == null || busy) return;
    final accountGeneration = home!.account.generation,
        interactionEpoch = home!.interaction.epoch,
        operation = ++epoch;
    bool live() =>
        !_disposed &&
        epoch == operation &&
        _sourceCurrent &&
        home!.interaction.epoch == interactionEpoch &&
        home!.account.isCurrent(accountGeneration);
    busy = true;
    failure = null;
    saved = false;
    _attempted = true;
    _emit();
    LarenorServerApi? transport;
    try {
      await home!.account.withSession((_, session) async {
        if (!live() ||
            session.context != original.context ||
            session.user.id != original.user.id ||
            session.endpoint.baseUrl != original.endpoint.baseUrl) {
          throw const LarenorServerException('cancelled');
        }
        transport = factory(session.endpoint);
        bool authoritative() => live() && identical(_ready, session) && fresh;
        CoreKeeneticApi api(HomeResourceRecord target) => CoreKeeneticApi(
          transport!,
          session.accessToken,
          target,
          isCurrent: authoritative,
        );
        try {
          await action(api);
        } catch (_) {
          if (!authoritative()) throw const LarenorServerException('cancelled');
          rethrow;
        }
        if (!authoritative()) throw const LarenorServerException('cancelled');
      });
    } catch (error) {
      if (live()) {
        _clear();
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      transport?.close();
      if (!_disposed && epoch == operation) {
        if (!live()) {
          _clear();
          failure = null;
        }
        busy = false;
        _emit();
      }
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _clear();
    await _run((api) async {
      final next = await api(target).resource();
      record = next;
      if (admin) {
        binding = await api(next).binding();
        services = await api(next).services();
        if (binding != null) {
          snapshot = await api(next).snapshot();
          details = await api(next).details();
        }
      } else {
        snapshot = await api(next).snapshot();
        details = await api(next).details();
      }
      loaded = true;
      if (snapshot != null) {
        _arm(snapshot!.remainingTtlMs);
      }
    });
  }

  Future<void> loadMoreDetails() async {
    final expectedRecord = record, currentPage = details;
    if (!fresh ||
        busy ||
        stale ||
        expectedRecord == null ||
        currentPage?.nextAfter == null) {
      return;
    }
    await _run((api) async {
      if (record != expectedRecord || details != currentPage) {
        throw const LarenorServerException('cancelled');
      }
      final next = await api(expectedRecord).details(
        after: currentPage!.nextAfter,
        expectedSnapshot: currentPage.snapshot,
      );
      details = currentPage.append(next);
      loaded = true;
    });
  }

  Future<void> createPreview(ServerService service) async {
    if (!canPreview ||
        service.verification.state !=
            ServerServiceVerificationState.authenticated) {
      return;
    }
    final expected = record;
    await _run((api) async {
      if (expected == null || record != expected) {
        throw const LarenorServerException('cancelled');
      }
      final value = await api(expected)
          .preview(service: service, existing: binding);
      preview = value;
      stale = false;
      _arm(value.expiresInMs);
      loaded = true;
    });
  }

  Future<void> confirm() async {
    final value = preview;
    if (!canConfirm || value == null || record == null) return;
    await _run((api) async {
      binding = await api(record!).confirm(value);
      preview = null;
      snapshot = null;
      saved = true;
      loaded = true;
    });
  }

  Future<void> cancelPreview() async {
    final value = preview;
    if (!canConfirm || value == null || record == null) return;
    await _run((api) async {
      await api(record!).cancel(value);
      preview = null;
      loaded = true;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    epoch++;
    _ttl?.cancel();
    home?.removeListener(_changed);
    home?.interaction.removeListener(_changed);
    home?.account.removeListener(_changed);
    owner.removeListener(_changed);
    super.dispose();
  }
}
