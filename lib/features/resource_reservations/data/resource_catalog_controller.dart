import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/resource_reservation_models.dart';

enum ResourceCatalogState {
  detached,
  loading,
  ready,
  busy,
  uncertain,
  offline,
  error,
}

final class ResourceCatalogController extends ChangeNotifier {
  ResourceCatalogController(this.api, {required this.commandIds});

  final ResourceCatalogApi api;
  final String Function() commandIds;
  ResourceCatalogState _state = ResourceCatalogState.detached;
  int _epoch = 0;
  int? _revision;
  bool _canManage = false;
  List<ReservationResource> _resources = const [];

  ResourceCatalogState get state => _state;
  int? get revision => _revision;
  bool get canManage => _canManage;
  List<ReservationResource> get resources => List.unmodifiable(_resources);

  int bind() {
    final lease = ++_epoch;
    _state = ResourceCatalogState.loading;
    _revision = null;
    _resources = const [];
    notifyListeners();
    unawaited(load(lease));
    return lease;
  }

  bool _current(int lease) => lease == _epoch;

  Future<void> load(int lease) async {
    if (!_current(lease)) return;
    _set(ResourceCatalogState.loading);
    try {
      final value = await api.resources();
      if (!_current(lease)) return;
      _revision = value.catalogRevision;
      _canManage = value.canManage;
      _resources = value.resources;
      _set(ResourceCatalogState.ready);
    } on TimeoutException {
      if (_current(lease)) _set(ResourceCatalogState.offline);
    } catch (_) {
      if (_current(lease)) _set(ResourceCatalogState.error);
    }
  }

  Future<void> create(
    int lease, {
    required String label,
    required String timezone,
    required int capacity,
  }) async {
    final revision = _revision;
    if (!_canMutate(lease, revision) || !_valid(label, timezone, capacity)) {
      return;
    }
    _set(ResourceCatalogState.busy);
    try {
      final receipt = await api.createResource(
        expectedCatalogRevision: revision!,
        commandId: commandIds(),
        label: label,
        timezone: timezone,
        capacity: capacity,
      );
      _accept(lease, revision, receipt, created: true);
    } on TimeoutException {
      if (_current(lease)) _set(ResourceCatalogState.uncertain);
    } catch (_) {
      if (_current(lease)) _set(ResourceCatalogState.error);
    }
  }

  Future<void> update(
    int lease,
    ReservationResource resource, {
    required String label,
    required String timezone,
    required int capacity,
  }) async {
    final revision = _revision;
    if (!_canMutate(lease, revision) ||
        !resource.active ||
        !_contains(resource) ||
        !_valid(label, timezone, capacity)) {
      return;
    }
    _set(ResourceCatalogState.busy);
    try {
      final receipt = await api.updateResource(
        expectedCatalogRevision: revision!,
        commandId: commandIds(),
        resource: resource,
        label: label,
        timezone: timezone,
        capacity: capacity,
      );
      _accept(lease, revision, receipt, previous: resource);
    } on TimeoutException {
      if (_current(lease)) _set(ResourceCatalogState.uncertain);
    } catch (_) {
      if (_current(lease)) _set(ResourceCatalogState.error);
    }
  }

  Future<void> deactivate(int lease, ReservationResource resource) async {
    final revision = _revision;
    if (!_canMutate(lease, revision) ||
        !resource.active ||
        !_contains(resource) ||
        _resources.where((item) => item.active).length <= 1) {
      return;
    }
    _set(ResourceCatalogState.busy);
    try {
      final receipt = await api.deactivateResource(
        expectedCatalogRevision: revision!,
        commandId: commandIds(),
        resource: resource,
      );
      _accept(lease, revision, receipt, previous: resource, deactivated: true);
    } on TimeoutException {
      if (_current(lease)) _set(ResourceCatalogState.uncertain);
    } catch (_) {
      if (_current(lease)) _set(ResourceCatalogState.error);
    }
  }

  bool _canMutate(int lease, int? revision) =>
      _current(lease) &&
      _state == ResourceCatalogState.ready &&
      _canManage &&
      revision != null;

  bool _contains(ReservationResource value) => _resources.any(
    (item) =>
        item.id == value.id &&
        item.revision == value.revision &&
        item.label == value.label &&
        item.timezone == value.timezone &&
        item.capacity == value.capacity &&
        item.active == value.active,
  );

  bool _valid(String label, String timezone, int capacity) =>
      label == label.trim() &&
      label.isNotEmpty &&
      label.length <= 80 &&
      timezone.isNotEmpty &&
      timezone.length <= 128 &&
      capacity >= 1 &&
      capacity <= 64;

  void _accept(
    int lease,
    int expectedRevision,
    ResourceCatalogReceipt receipt, {
    ReservationResource? previous,
    bool created = false,
    bool deactivated = false,
  }) {
    if (!_current(lease)) return;
    final validTransition =
        receipt.catalogRevision == expectedRevision + 1 &&
        receipt.resource.active == !deactivated &&
        (created
            ? !_resources.any((item) => item.id == receipt.resource.id) &&
                  receipt.resource.revision == 1
            : previous != null &&
                  receipt.resource.id == previous.id &&
                  receipt.resource.revision == previous.revision + 1);
    if (!validTransition) {
      _set(ResourceCatalogState.error);
      return;
    }
    _resources = List.unmodifiable(
      [
        ..._resources.where((item) => item.id != receipt.resource.id),
        receipt.resource,
      ]..sort((a, b) => a.label.compareTo(b.label)),
    );
    _revision = receipt.catalogRevision;
    _set(ResourceCatalogState.ready);
  }

  void retire() {
    _epoch++;
    _state = ResourceCatalogState.detached;
    _revision = null;
    _canManage = false;
    _resources = const [];
    notifyListeners();
  }

  void _set(ResourceCatalogState value) {
    _state = value;
    notifyListeners();
  }
}
