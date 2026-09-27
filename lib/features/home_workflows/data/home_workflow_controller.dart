import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_workflow_models.dart';
import 'home_workflow_api.dart';

enum HomeWorkflowViewState {
  detached,
  idle,
  loading,
  ready,
  empty,
  busy,
  uncertain,
  offline,
  error,
}

final class HomeWorkflowLease {
  const HomeWorkflowLease._(this.epoch);
  final int epoch;
}

enum _PendingKind { create, decision, resume }

final class _PendingOperation {
  const _PendingOperation({
    required this.kind,
    required this.operationId,
    this.workflowId,
    this.expectedRevision,
  });

  final _PendingKind kind;
  final String operationId;
  final String? workflowId;
  final int? expectedRevision;
}

final class HomeWorkflowController extends ChangeNotifier {
  HomeWorkflowController(this._api, {required this.operationIds});

  final HomeWorkflowApi _api;
  final String Function() operationIds;
  List<HomeWorkflow> _workflows = const [];
  HomeWorkflowViewState _state = HomeWorkflowViewState.detached;
  String? _nextBefore;
  _PendingOperation? _pending;
  int _epoch = 0;
  bool _disposed = false;
  String? failure;

  List<HomeWorkflow> get workflows => List.unmodifiable(_workflows);
  HomeWorkflowViewState get state => _state;
  String? get nextBefore => _nextBefore;
  bool get canLoadMore =>
      _nextBefore != null && _state == HomeWorkflowViewState.ready;

  HomeWorkflowLease bind() {
    _epoch++;
    _workflows = const [];
    _nextBefore = null;
    _pending = null;
    failure = null;
    _state = HomeWorkflowViewState.idle;
    _emit();
    return HomeWorkflowLease._(_epoch);
  }

  void detach(HomeWorkflowLease lease) {
    if (!_current(lease)) return;
    _epoch++;
    _workflows = const [];
    _nextBefore = null;
    _pending = null;
    failure = null;
    _state = HomeWorkflowViewState.detached;
    _emit();
  }

  bool _current(HomeWorkflowLease lease) => !_disposed && lease.epoch == _epoch;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _set(HomeWorkflowViewState value, {String? error}) {
    _state = value;
    failure = error;
    _emit();
  }

  void _ready() {
    _set(
      _workflows.isEmpty
          ? HomeWorkflowViewState.empty
          : HomeWorkflowViewState.ready,
    );
  }

  bool _validId(String value) =>
      value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  String _newId() {
    final result = operationIds();
    if (!_validId(result)) {
      throw const LarenorServerException('invalid_request');
    }
    return result;
  }

  Future<void> load(HomeWorkflowLease lease, {bool more = false}) async {
    if (!_current(lease) ||
        _state == HomeWorkflowViewState.loading ||
        _state == HomeWorkflowViewState.busy ||
        _state == HomeWorkflowViewState.uncertain ||
        more && !canLoadMore) {
      return;
    }
    final before = more ? _nextBefore : null;
    if (!more) {
      _workflows = const [];
      _nextBefore = null;
    }
    _set(HomeWorkflowViewState.loading);
    try {
      final page = await _api.list(before: before);
      if (!_current(lease)) return;
      final combined = <HomeWorkflow>[
        if (more) ..._workflows,
        ...page.workflows,
      ];
      final ids = <String>{};
      if (combined.length > HomeWorkflow.maximumRecords ||
          combined.any((workflow) => !ids.add(workflow.id))) {
        throw const LarenorServerException('invalid_response');
      }
      _workflows = List.unmodifiable(combined);
      _nextBefore = page.nextBefore;
      _ready();
    } on TimeoutException {
      if (_current(lease)) _set(HomeWorkflowViewState.offline);
    } catch (error) {
      if (_current(lease)) {
        _set(
          HomeWorkflowViewState.error,
          error: error is LarenorServerException
              ? error.code
              : 'invalid_response',
        );
      }
    }
  }

  HomeWorkflow? _currentWorkflow(HomeWorkflow candidate) {
    for (final workflow in _workflows) {
      if (workflow.id == candidate.id &&
          workflow.revision == candidate.revision) {
        return workflow;
      }
    }
    return null;
  }

  void _accept(HomeWorkflow workflow, {bool created = false}) {
    final next = <HomeWorkflow>[
      if (created && !_workflows.any((item) => item.id == workflow.id))
        workflow,
      for (final item in _workflows)
        if (item.id == workflow.id) workflow else item,
    ];
    _workflows = List.unmodifiable(next);
    _pending = null;
    _ready();
  }

  Future<void> create(
    HomeWorkflowLease lease, {
    required String title,
    required int deadlineSeconds,
    required HomeResourceRecord target,
    required HomeWorkflowAction action,
  }) async {
    if (!_canMutate(lease)) return;
    late final String requestId;
    try {
      requestId = _newId();
    } catch (error) {
      _set(HomeWorkflowViewState.error, error: 'invalid_request');
      return;
    }
    _pending = _PendingOperation(
      kind: _PendingKind.create,
      operationId: requestId,
    );
    _set(HomeWorkflowViewState.busy);
    try {
      final workflow = await _api.create(
        requestId: requestId,
        title: title,
        deadlineSeconds: deadlineSeconds,
        target: target,
        action: action,
      );
      if (!_current(lease)) return;
      if (workflow.requestId != requestId) {
        _pending = null;
        _set(HomeWorkflowViewState.error, error: 'invalid_response');
        return;
      }
      _accept(workflow, created: true);
    } on TimeoutException {
      if (_current(lease)) _set(HomeWorkflowViewState.uncertain);
    } catch (error) {
      if (_current(lease)) {
        _pending = null;
        _set(
          HomeWorkflowViewState.error,
          error: error is LarenorServerException
              ? error.code
              : 'invalid_response',
        );
      }
    }
  }

  bool _canMutate(HomeWorkflowLease lease) =>
      _current(lease) &&
      (_state == HomeWorkflowViewState.ready ||
          _state == HomeWorkflowViewState.empty) &&
      _pending == null;

  Future<void> approve(HomeWorkflowLease lease, HomeWorkflow workflow) =>
      _decide(lease, workflow, HomeWorkflowDecision.approve);

  Future<void> cancel(HomeWorkflowLease lease, HomeWorkflow workflow) =>
      _decide(lease, workflow, HomeWorkflowDecision.cancel);

  Future<void> effectApplied(HomeWorkflowLease lease, HomeWorkflow workflow) =>
      _decide(lease, workflow, HomeWorkflowDecision.effectApplied);

  Future<void> effectNotApplied(
    HomeWorkflowLease lease,
    HomeWorkflow workflow,
  ) => _decide(lease, workflow, HomeWorkflowDecision.effectNotApplied);

  bool _decisionAllowed(HomeWorkflow workflow, HomeWorkflowDecision decision) {
    return switch (decision) {
      HomeWorkflowDecision.approve || HomeWorkflowDecision.cancel =>
        workflow.state == HomeWorkflowState.waitingDecision &&
            workflow.decisionRequired ==
                HomeWorkflowDecisionRequired.approveEffect,
      HomeWorkflowDecision.effectApplied ||
      HomeWorkflowDecision.effectNotApplied =>
        workflow.state == HomeWorkflowState.reconciliationRequired &&
            workflow.decisionRequired ==
                HomeWorkflowDecisionRequired.reconcileEffect,
    };
  }

  Future<void> _decide(
    HomeWorkflowLease lease,
    HomeWorkflow candidate,
    HomeWorkflowDecision decision,
  ) async {
    if (!_canMutate(lease)) return;
    final workflow = _currentWorkflow(candidate);
    if (workflow == null || !_decisionAllowed(workflow, decision)) {
      _set(HomeWorkflowViewState.error, error: 'invalid_request');
      return;
    }
    late final String decisionId;
    try {
      decisionId = _newId();
    } catch (_) {
      _set(HomeWorkflowViewState.error, error: 'invalid_request');
      return;
    }
    _pending = _PendingOperation(
      kind: _PendingKind.decision,
      operationId: decisionId,
      workflowId: workflow.id,
      expectedRevision: workflow.revision,
    );
    _set(HomeWorkflowViewState.busy);
    try {
      final result = await _api.decide(
        workflow: workflow,
        decisionId: decisionId,
        decision: decision,
      );
      if (!_current(lease)) return;
      if (result.id != workflow.id || result.revision <= workflow.revision) {
        _pending = null;
        _set(HomeWorkflowViewState.error, error: 'invalid_response');
        return;
      }
      _accept(result);
    } on TimeoutException {
      if (_current(lease)) _set(HomeWorkflowViewState.uncertain);
    } catch (error) {
      if (_current(lease)) {
        _pending = null;
        _set(
          HomeWorkflowViewState.error,
          error: error is LarenorServerException
              ? error.code
              : 'invalid_response',
        );
      }
    }
  }

  Future<void> resume(HomeWorkflowLease lease, HomeWorkflow candidate) async {
    if (!_canMutate(lease)) return;
    final workflow = _currentWorkflow(candidate);
    if (workflow == null ||
        workflow.state != HomeWorkflowState.reconciliationRequired) {
      _set(HomeWorkflowViewState.error, error: 'invalid_request');
      return;
    }
    late final String resumeId;
    try {
      resumeId = _newId();
    } catch (_) {
      _set(HomeWorkflowViewState.error, error: 'invalid_request');
      return;
    }
    _pending = _PendingOperation(
      kind: _PendingKind.resume,
      operationId: resumeId,
      workflowId: workflow.id,
      expectedRevision: workflow.revision,
    );
    _set(HomeWorkflowViewState.busy);
    try {
      final result = await _api.resume(workflow: workflow, resumeId: resumeId);
      if (!_current(lease)) return;
      if (result.id != workflow.id || result.revision < workflow.revision) {
        _pending = null;
        _set(HomeWorkflowViewState.error, error: 'invalid_response');
        return;
      }
      _accept(result);
    } on TimeoutException {
      if (_current(lease)) _set(HomeWorkflowViewState.uncertain);
    } catch (error) {
      if (_current(lease)) {
        _pending = null;
        _set(
          HomeWorkflowViewState.error,
          error: error is LarenorServerException
              ? error.code
              : 'invalid_response',
        );
      }
    }
  }

  /// A timed-out mutation is never posted again here. Only authoritative GETs
  /// may resolve it: detail for an existing workflow, or a bounded list scan
  /// for an uncertain create whose workflow id is not known yet.
  Future<void> reconcile(HomeWorkflowLease lease) async {
    final pending = _pending;
    if (!_current(lease) ||
        pending == null ||
        _state != HomeWorkflowViewState.uncertain) {
      return;
    }
    try {
      if (pending.kind == _PendingKind.create) {
        String? before;
        var seen = 0;
        do {
          final page = await _api.list(before: before);
          if (!_current(lease)) return;
          for (final workflow in page.workflows) {
            seen++;
            if (workflow.requestId == pending.operationId) {
              _accept(workflow, created: true);
              return;
            }
          }
          if (seen > HomeWorkflow.maximumRecords || page.nextBefore == before) {
            throw const LarenorServerException('invalid_response');
          }
          before = page.nextBefore;
        } while (before != null);
        return;
      }

      final workflowId = pending.workflowId!;
      final workflow = await _api.detail(workflowId);
      if (!_current(lease)) return;
      final expected = pending.expectedRevision!;
      if (workflow.revision > expected ||
          pending.kind == _PendingKind.resume &&
              workflow.revision >= expected) {
        _accept(workflow);
      }
    } on TimeoutException {
      // Retain the uncertain operation. A later explicit GET may resolve it.
    } catch (error) {
      if (_current(lease)) {
        _pending = null;
        _set(
          HomeWorkflowViewState.error,
          error: error is LarenorServerException
              ? error.code
              : 'invalid_response',
        );
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _workflows = const [];
    _pending = null;
    super.dispose();
  }
}
