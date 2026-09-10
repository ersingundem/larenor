import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';
import 'core_bounded_download_api.dart';
import 'core_bounded_download_file_access.dart';

typedef CoreBoundedDownloadApiFactory = CoreBoundedDownloadApi Function(
  ServerEndpoint endpoint,
);

final coreBoundedDownloadApiFactoryProvider =
    Provider<CoreBoundedDownloadApiFactory>(
      (_) =>
          (endpoint) => CoreBoundedDownloadApi(endpoint: endpoint),
    );

enum CoreBoundedDownloadPhase {
  idle,
  downloading,
  choosingDestination,
  saved,
  cancelled,
  unauthorized,
  forbidden,
  changed,
  lateFrame,
  failed,
}

/// One visible, user-started operation. Account/home/lifecycle changes close
/// the transport and invalidate every late callback before SAF publication.
final class CoreBoundedDownloadController extends ChangeNotifier {
  CoreBoundedDownloadController(
    this.home,
    this.apiFactory,
    this.files,
    this.clock,
    this.windowCurrent,
  ) {
    home.addListener(_changed);
    home.account.addListener(_changed);
  }

  final HomeSessionController home;
  final CoreBoundedDownloadApiFactory apiFactory;
  final CoreBoundedDownloadFileAccess files;
  final DateTime Function() clock;
  final bool Function() windowCurrent;
  CoreBoundedDownloadPhase phase = CoreBoundedDownloadPhase.idle;
  String? targetId, traceId;
  int epoch = 0;
  bool _disposed = false, _visible = false, busy = false;
  CoreBoundedDownloadApi? _transport;
  ServerSession? _boundSession;
  HomeResourceRecord? _boundTarget;
  int? _boundUserRevision;

  ServerSession? get _ready {
    final account = home.account, session = account.session;
    if (_disposed ||
        !_visible ||
        !windowCurrent() ||
        home.source != HomeSource.verifiedCore ||
        !home.interaction.active ||
        home.busy ||
        home.failure != null ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        session.expiresSoon(clock())) {
      return null;
    }
    return session;
  }

  bool canDownload(HomeResourceRecord target, int? userRevision) =>
      !busy &&
      _ready?.context == target.context &&
      target.kind == HomeResourceKind.resource &&
      userRevision != null &&
      userRevision >= 1 &&
      userRevision <= 9223372036854775807;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    if (!value) _retire();
    _emit();
  }

  void _changed() {
    if (_disposed) return;
    if (_ready == null || (busy && !identical(_ready, _boundSession))) {
      _retire();
    }
    _emit();
  }

  void retainAuthority(List<HomeResourceRecord> entries, int? userRevision) {
    final target = _boundTarget;
    if (!busy || target == null) return;
    final retained =
        userRevision == _boundUserRevision &&
        entries.any(
          (entry) =>
              entry.context == target.context &&
              entry.id == target.id &&
              entry.kind == target.kind &&
              entry.revision == target.revision &&
              entry.aclRevision == target.aclRevision,
        );
    if (!retained) {
      _retire();
      _emit();
    }
  }

  void _retire() {
    epoch++;
    _transport?.close();
    _transport = null;
    busy = false;
    targetId = null;
    traceId = null;
    _boundSession = null;
    _boundTarget = null;
    _boundUserRevision = null;
    phase = CoreBoundedDownloadPhase.idle;
  }

  Future<void> download(
    HomeResourceRecord target, {
    required int userRevision,
    required bool Function() isCurrent,
  }) async {
    final original = _ready;
    if (original == null || !canDownload(target, userRevision)) return;
    final operation = ++epoch;
    final generation = home.account.generation;
    final homeEpoch = home.interaction.epoch;
    bool safeGuard() {
      try {
        return isCurrent();
      } catch (_) {
        return false;
      }
    }

    bool current() =>
        !_disposed &&
        epoch == operation &&
        _ready != null &&
        home.interaction.epoch == homeEpoch &&
        home.account.isCurrent(generation) &&
        identical(home.account.session, original) &&
        safeGuard();
    busy = true;
    phase = CoreBoundedDownloadPhase.downloading;
    targetId = target.id;
    _boundSession = original;
    _boundTarget = target;
    _boundUserRevision = userRevision;
    traceId = null;
    _emit();
    try {
      CoreBoundedBlob? blob;
      await home.account.withSession((_, session) async {
        if (!current() ||
            session.context != target.context ||
            session.user.id != original.user.id ||
            session.endpoint.baseUrl != original.endpoint.baseUrl) {
          throw const LarenorServerException('cancelled');
        }
        _transport = apiFactory(session.endpoint);
        try {
          blob = await _transport!.download(
            token: session.accessToken,
            target: target,
            expectedUserRevision: userRevision,
            // The synthetic v1 pilot provider starts at revision one. Product
            // provider discovery remains outside this bounded slice.
            expectedServiceRevision: 1,
          );
        } on CoreBoundedDownloadException catch (error) {
          if (error.code == 'unauthorized') {
            throw const LarenorServerException('unauthorized');
          }
          rethrow;
        }
      });
      if (!current() || blob == null) return;
      traceId = blob!.traceId;
      phase = CoreBoundedDownloadPhase.choosingDestination;
      _emit();
      final saved = await files.publish(blob!, target.id);
      if (!current()) return;
      phase = saved
          ? CoreBoundedDownloadPhase.saved
          : CoreBoundedDownloadPhase.cancelled;
    } catch (error) {
      if (current()) {
        final code = switch (error) {
          CoreBoundedDownloadException e => e.code,
          LarenorServerException e => e.code,
          _ => 'failed',
        };
        phase = switch (code) {
          'cancelled' => CoreBoundedDownloadPhase.cancelled,
          'unauthorized' => CoreBoundedDownloadPhase.unauthorized,
          'forbidden' => CoreBoundedDownloadPhase.forbidden,
          'revision_conflict' => CoreBoundedDownloadPhase.changed,
          'late_frame' => CoreBoundedDownloadPhase.lateFrame,
          _ => CoreBoundedDownloadPhase.failed,
        };
      }
    } finally {
      _transport?.close();
      _transport = null;
      if (!_disposed && epoch == operation) {
        if (!safeGuard()) {
          phase = CoreBoundedDownloadPhase.cancelled;
          traceId = null;
        }
        busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retire();
    home.removeListener(_changed);
    home.account.removeListener(_changed);
    super.dispose();
  }
}
