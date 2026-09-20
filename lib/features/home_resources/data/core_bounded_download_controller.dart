import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';
import 'core_bounded_download_api.dart';
import 'core_bounded_download_file_access.dart';
import 'core_bounded_upload_file_access.dart';

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

enum CoreBoundedHistoryPhase {
  idle,
  loading,
  ready,
  cancelled,
  unauthorized,
  forbidden,
  changed,
  failed,
}

enum CoreBoundedUploadPhase {
  idle,
  choosingSource,
  uploading,
  uploaded,
  cancelled,
  unauthorized,
  forbidden,
  changed,
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
    this.windowCurrent, [
    CoreBoundedUploadFileAccess? uploadFiles,
  ]) : uploadFiles = uploadFiles ?? CoreBoundedUploadFileAccess() {
    home.addListener(_changed);
    home.account.addListener(_changed);
  }

  final HomeSessionController home;
  final CoreBoundedDownloadApiFactory apiFactory;
  final CoreBoundedDownloadFileAccess files;
  final CoreBoundedUploadFileAccess uploadFiles;
  final DateTime Function() clock;
  final bool Function() windowCurrent;
  CoreBoundedDownloadPhase phase = CoreBoundedDownloadPhase.idle;
  CoreBoundedHistoryPhase historyPhase = CoreBoundedHistoryPhase.idle;
  CoreBoundedUploadPhase uploadPhase = CoreBoundedUploadPhase.idle;
  List<CoreBoundedTransferReceipt> history = const [];
  String? targetId, traceId;
  String? historyTargetId;
  String? uploadTargetId, uploadRequestId;
  CoreBoundedBlobDescriptor? descriptor;
  CoreBoundedTransferReceipt? receipt;
  bool receiptTrusted = false;
  bool _serviceReachable = false;
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
      historyPhase != CoreBoundedHistoryPhase.loading &&
      _ready?.context == target.context &&
      target.kind == HomeResourceKind.resource &&
      userRevision != null &&
      userRevision >= 1 &&
      userRevision <= 9223372036854775807;

  bool get serviceReachable => _serviceReachable;

  bool get intentRegistered =>
      targetId != null && phase != CoreBoundedDownloadPhase.idle;

  bool get providerAccepted =>
      receiptTrusted && receipt?.state == CoreBoundedTransferState.completed;

  bool get deviceResultObserved =>
      providerAccepted && phase == CoreBoundedDownloadPhase.saved;

  bool canLoadHistory(HomeResourceRecord target) =>
      !busy &&
      historyPhase != CoreBoundedHistoryPhase.loading &&
      _ready?.context == target.context &&
      target.kind == HomeResourceKind.resource;

  bool canUpload(HomeResourceRecord target, int? userRevision) =>
      !busy &&
      historyPhase != CoreBoundedHistoryPhase.loading &&
      _ready?.context == target.context &&
      target.kind == HomeResourceKind.resource &&
      target.canWrite &&
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
    final boundSession = _boundSession;
    if (_ready == null ||
        (boundSession != null && !identical(_ready, boundSession))) {
      _retire();
    }
    _emit();
  }

  void retainAuthority(List<HomeResourceRecord> entries, int? userRevision) {
    final target = _boundTarget;
    if (target == null) return;
    final retained =
        (_boundUserRevision == null || userRevision == _boundUserRevision) &&
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
    _boundSession = null;
    _boundTarget = null;
    _boundUserRevision = null;
    _clearDownloadEvidence();
    _clearHistoryEvidence();
    _clearUploadEvidence();
  }

  void _clearDownloadEvidence() {
    targetId = null;
    traceId = null;
    receipt = null;
    receiptTrusted = false;
    _serviceReachable = false;
    phase = CoreBoundedDownloadPhase.idle;
  }

  void _clearHistoryEvidence() {
    historyPhase = CoreBoundedHistoryPhase.idle;
    history = const [];
    historyTargetId = null;
  }

  void _clearUploadEvidence() {
    uploadPhase = CoreBoundedUploadPhase.idle;
    uploadTargetId = null;
    uploadRequestId = null;
    descriptor = null;
  }

  Future<void> chooseAndUpload(
    HomeResourceRecord target, {
    required int userRevision,
    required bool Function() isCurrent,
  }) async {
    final original = _ready;
    if (original == null || !canUpload(target, userRevision)) return;
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
    _clearDownloadEvidence();
    _clearHistoryEvidence();
    _clearUploadEvidence();
    busy = true;
    uploadTargetId = target.id;
    uploadPhase = CoreBoundedUploadPhase.choosingSource;
    _boundSession = original;
    _boundTarget = target;
    _boundUserRevision = userRevision;
    _emit();
    var handedOff = false;
    try {
      final source = await uploadFiles.pick();
      if (!current()) return;
      if (source == null) {
        uploadPhase = CoreBoundedUploadPhase.cancelled;
        return;
      }
      // upload() executes synchronously through its new epoch/busy claim before
      // its first await, leaving no interleaving point between the two phases.
      busy = false;
      final next = upload(
        target,
        source: source,
        userRevision: userRevision,
        isCurrent: isCurrent,
      );
      handedOff = epoch != operation && busy;
      if (!handedOff) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      await next;
    } catch (_) {
      if (current()) {
        uploadPhase = CoreBoundedUploadPhase.failed;
      }
    } finally {
      if (!handedOff && !_disposed && epoch == operation) {
        if (!safeGuard()) {
          uploadPhase = CoreBoundedUploadPhase.cancelled;
        }
        busy = false;
        _emit();
      }
    }
  }

  Future<void> upload(
    HomeResourceRecord target, {
    required CoreBoundedUploadSource source,
    required int userRevision,
    required bool Function() isCurrent,
  }) async {
    final original = _ready;
    if (original == null || !canUpload(target, userRevision)) return;
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
    _clearDownloadEvidence();
    _clearHistoryEvidence();
    busy = true;
    uploadTargetId = target.id;
    uploadRequestId = null;
    descriptor = null;
    uploadPhase = CoreBoundedUploadPhase.uploading;
    _boundSession = original;
    _boundTarget = target;
    _boundUserRevision = userRevision;
    _emit();
    CoreBoundedDownloadApi? transport;
    try {
      CoreBoundedBlobUploadResult? result;
      await home.account.withSession((_, session) async {
        if (!current() ||
            session.context != target.context ||
            session.user.id != original.user.id ||
            session.endpoint.baseUrl != original.endpoint.baseUrl) {
          throw const LarenorServerException('cancelled');
        }
        transport = apiFactory(session.endpoint);
        _transport = transport;
        var serviceRevision = 0;
        try {
          serviceRevision = (await transport!.descriptor(
            token: session.accessToken,
            target: target,
          )).serviceRevision;
        } on CoreBoundedDownloadException catch (error) {
          if (error.code != 'not_found') rethrow;
        }
        if (!current()) {
          throw const CoreBoundedDownloadException('cancelled');
        }
        result = await transport!.upload(
          token: session.accessToken,
          target: target,
          expectedUserRevision: userRevision,
          expectedServiceRevision: serviceRevision,
          source: source,
        );
      });
      if (!current() || result == null) return;
      descriptor = result!.descriptor;
      uploadRequestId = result!.requestId;
      uploadPhase = CoreBoundedUploadPhase.uploaded;
    } catch (error) {
      if (current()) {
        descriptor = null;
        uploadRequestId = null;
        final code = switch (error) {
          CoreBoundedDownloadException e => e.code,
          LarenorServerException e => e.code,
          _ => 'failed',
        };
        uploadPhase = switch (code) {
          'cancelled' => CoreBoundedUploadPhase.cancelled,
          'unauthorized' => CoreBoundedUploadPhase.unauthorized,
          'forbidden' => CoreBoundedUploadPhase.forbidden,
          'revision_conflict' => CoreBoundedUploadPhase.changed,
          _ => CoreBoundedUploadPhase.failed,
        };
      }
    } finally {
      if (identical(_transport, transport)) _transport = null;
      transport?.close();
      if (!_disposed && epoch == operation) {
        if (!safeGuard()) {
          uploadPhase = CoreBoundedUploadPhase.cancelled;
          descriptor = null;
          uploadRequestId = null;
        }
        busy = false;
        _emit();
      }
    }
  }

  Future<void> loadHistory(
    HomeResourceRecord target, {
    required bool Function() isCurrent,
  }) async {
    final original = _ready;
    if (original == null || !canLoadHistory(target)) return;
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
    _clearDownloadEvidence();
    _clearUploadEvidence();
    historyPhase = CoreBoundedHistoryPhase.loading;
    history = const [];
    historyTargetId = target.id;
    _boundSession = original;
    _boundTarget = target;
    _boundUserRevision = null;
    _emit();
    CoreBoundedDownloadApi? transport;
    try {
      List<CoreBoundedTransferReceipt>? loaded;
      await home.account.withSession((_, session) async {
        if (!current() ||
            session.context != target.context ||
            session.user.id != original.user.id ||
            session.endpoint.baseUrl != original.endpoint.baseUrl) {
          throw const LarenorServerException('cancelled');
        }
        transport = apiFactory(session.endpoint);
        _transport = transport;
        loaded = await transport!.history(
          token: session.accessToken,
          target: target,
        );
      });
      if (!current() || loaded == null) return;
      history = List.unmodifiable(loaded!);
      historyPhase = CoreBoundedHistoryPhase.ready;
    } catch (error) {
      if (current()) {
        final code = switch (error) {
          CoreBoundedDownloadException e => e.code,
          LarenorServerException e => e.code,
          _ => 'failed',
        };
        historyPhase = switch (code) {
          'cancelled' => CoreBoundedHistoryPhase.cancelled,
          'unauthorized' => CoreBoundedHistoryPhase.unauthorized,
          'forbidden' => CoreBoundedHistoryPhase.forbidden,
          'revision_conflict' => CoreBoundedHistoryPhase.changed,
          _ => CoreBoundedHistoryPhase.failed,
        };
      }
    } finally {
      if (identical(_transport, transport)) _transport = null;
      transport?.close();
      if (!_disposed && epoch == operation) {
        if (!safeGuard()) {
          historyPhase = CoreBoundedHistoryPhase.cancelled;
          history = const [];
        }
        _emit();
      }
    }
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
    _clearHistoryEvidence();
    _clearUploadEvidence();
    busy = true;
    phase = CoreBoundedDownloadPhase.downloading;
    targetId = target.id;
    _boundSession = original;
    _boundTarget = target;
    _boundUserRevision = userRevision;
    traceId = null;
    receipt = null;
    receiptTrusted = false;
    _serviceReachable = false;
    _emit();
    CoreBoundedDownloadApi? transport;
    try {
      CoreBoundedBlob? blob;
      CoreBoundedTransferReceipt? verifiedReceipt;
      await home.account.withSession((_, session) async {
        if (!current() ||
            session.context != target.context ||
            session.user.id != original.user.id ||
            session.endpoint.baseUrl != original.endpoint.baseUrl) {
          throw const LarenorServerException('cancelled');
        }
        transport = apiFactory(session.endpoint);
        _transport = transport;
        try {
          final currentDescriptor = await transport!.descriptor(
            token: session.accessToken,
            target: target,
          );
          if (!current()) {
            throw const CoreBoundedDownloadException('cancelled');
          }
          _serviceReachable = true;
          _emit();
          final candidate = await transport!.download(
            token: session.accessToken,
            target: target,
            expectedUserRevision: userRevision,
            expectedServiceRevision: currentDescriptor.serviceRevision,
          );
          if (!currentDescriptor.authenticatesBlob(candidate)) {
            throw const CoreBoundedDownloadException('invalid_response');
          }
          if (!current()) {
            throw const CoreBoundedDownloadException('cancelled');
          }
          verifiedReceipt = await transport!.verifyCompleted(
            token: session.accessToken,
            target: target,
            blob: candidate,
          );
          if (!current()) {
            throw const CoreBoundedDownloadException('cancelled');
          }
          blob = candidate;
        } on CoreBoundedDownloadException catch (error) {
          if (error.code == 'unauthorized') {
            throw const LarenorServerException('unauthorized');
          }
          rethrow;
        }
      });
      if (!current() || blob == null || verifiedReceipt == null) return;
      receipt = verifiedReceipt;
      receiptTrusted = true;
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
        if (!receiptTrusted) receipt = null;
        final code = switch (error) {
          CoreBoundedDownloadException e => e.code,
          LarenorServerException e => e.code,
          _ => 'failed',
        };
        if (const {
          'forbidden',
          'not_found',
          'revision_conflict',
          'payload_too_large',
          'rate_limited',
          'server_error',
          'failed',
          'invalid_response',
          'late_frame',
          'file_access_failed',
        }.contains(code)) {
          _serviceReachable = true;
        }
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
      if (identical(_transport, transport)) _transport = null;
      transport?.close();
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
