import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/family_board_models.dart';

abstract interface class FamilyBoardGateway {
  Future<FamilyBoardSnapshot> read(FamilyBoardBinding authority);
  Future<FamilyBoardDelta> delta(
    FamilyBoardBinding authority, {
    required int afterSequence,
  });
  Future<FamilyBoardReceipt> mutate(
    FamilyBoardBinding authority,
    FamilyBoardCommand command,
  );
}

abstract interface class FamilyBoardCache {
  Future<FamilyBoardSnapshot?> read(
    FamilyBoardBinding authority, {
    required bool Function() isCurrent,
  });
  Future<void> write(
    FamilyBoardSnapshot snapshot, {
    required bool Function() isCurrent,
  });
}

enum BoardFailure { offline, conflict, stale, invalidResponse }

final class FamilyBoardController extends ChangeNotifier {
  FamilyBoardController({
    required this.gateway,
    required this.cache,
    required this.binding,
    required this.isCurrent,
    String Function()? idFactory,
  }) : _idFactory = idFactory ?? _secureIdentity;
  final FamilyBoardGateway gateway;
  final FamilyBoardCache cache;
  final FamilyBoardBinding binding;
  final bool Function(FamilyBoardBinding binding) isCurrent;
  final String Function() _idFactory;
  FamilyBoardSnapshot? snapshot;
  BoardFailure? failure;
  bool busy = false, offline = false, _retired = false;
  int _epoch = 0;

  static String _secureIdentity() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  bool _current(int operation) {
    try {
      return !_retired &&
          operation == _epoch &&
          binding.active &&
          isCurrent(binding);
    } catch (_) {
      return false;
    }
  }

  bool get canMutate =>
      !busy &&
      !offline &&
      failure != BoardFailure.conflict &&
      binding.canWrite &&
      _current(_epoch) &&
      snapshot != null;

  void _stale(int operation) {
    if (operation != _epoch || _retired) return;
    snapshot = null;
    busy = false;
    offline = false;
    failure = BoardFailure.stale;
    notifyListeners();
  }

  Future<void> load() async {
    if (!_current(_epoch) || busy) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    offline = false;
    notifyListeners();
    try {
      final value = await gateway.read(binding);
      if (!_current(operation) || value.binding != binding) {
        return _stale(operation);
      }
      snapshot = value;
      await cache.write(value, isCurrent: () => _current(operation));
      if (!_current(operation)) return _stale(operation);
    } on FamilyBoardException catch (error) {
      if (!_current(operation)) return _stale(operation);
      if (const {
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        FamilyBoardSnapshot? retained;
        try {
          retained = await cache.read(
            binding,
            isCurrent: () => _current(operation),
          );
        } on FamilyBoardException {
          if (!_current(operation)) return _stale(operation);
          retained = null;
        }
        if (!_current(operation)) return _stale(operation);
        snapshot = retained;
        offline = retained != null;
        failure = retained == null ? BoardFailure.offline : null;
      } else {
        snapshot = null;
        failure = BoardFailure.invalidResponse;
      }
    } catch (_) {
      if (_current(operation)) {
        snapshot = null;
        failure = BoardFailure.invalidResponse;
      }
    } finally {
      if (_current(operation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> createCard(String text) async {
    final value = snapshot;
    if (!canMutate || value == null) return;
    FamilyBoardCommand command;
    try {
      final card = BoardCard(
        id: _idFactory(),
        text: text,
        x: 24,
        y: 24,
        color: 'yellow',
      );
      command = FamilyBoardCommand.append(
        _idFactory(),
        value.boardRevision,
        card,
      );
    } catch (_) {
      failure = BoardFailure.invalidResponse;
      notifyListeners();
      return;
    }
    await _mutate(command);
  }

  Future<void> updateCard(String id, String text) async {
    final value = snapshot;
    if (!canMutate || value == null) return;
    final previous = value.cards.where((card) => card.id == id).firstOrNull;
    if (previous == null) return;
    FamilyBoardCommand command;
    try {
      final card = BoardCard(
        id: id,
        text: text,
        x: previous.x,
        y: previous.y,
        color: previous.color,
      );
      command = FamilyBoardCommand.update(
        _idFactory(),
        value.boardRevision,
        card,
      );
    } catch (_) {
      failure = BoardFailure.invalidResponse;
      notifyListeners();
      return;
    }
    await _mutate(command);
  }

  Future<void> deleteElement(String id) async {
    final value = snapshot;
    if (!canMutate ||
        value == null ||
        !value.elements.any((element) => element.id == id)) {
      return;
    }
    FamilyBoardCommand command;
    try {
      command = FamilyBoardCommand.delete(
        _idFactory(),
        value.boardRevision,
        id,
      );
    } catch (_) {
      failure = BoardFailure.invalidResponse;
      notifyListeners();
      return;
    }
    await _mutate(command);
  }

  Future<void> appendStroke(List<BoardPoint> points) async {
    final value = snapshot;
    if (!canMutate || value == null) return;
    FamilyBoardCommand command;
    try {
      final stroke = BoardStroke(
        id: _idFactory(),
        color: 'blue',
        width: 4,
        points: points,
      );
      command = FamilyBoardCommand.append(
        _idFactory(),
        value.boardRevision,
        stroke,
      );
    } catch (_) {
      failure = BoardFailure.invalidResponse;
      notifyListeners();
      return;
    }
    await _mutate(command);
  }

  Future<void> _mutate(FamilyBoardCommand command) async {
    if (!canMutate) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final receipt = await gateway.mutate(binding, command);
      if (!_current(operation) || receipt.boardId != binding.boardId) {
        return _stale(operation);
      }
      final readback = await gateway.read(binding);
      if (!_current(operation) ||
          readback.binding != binding ||
          readback.boardRevision != receipt.boardRevision) {
        return _stale(operation);
      }
      snapshot = readback;
      await cache.write(readback, isCurrent: () => _current(operation));
      if (!_current(operation)) return _stale(operation);
    } on FamilyBoardException catch (error) {
      if (!_current(operation)) return _stale(operation);
      if (error.code == 'revision_conflict') {
        failure = BoardFailure.conflict;
      } else if (const {
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        offline = snapshot != null;
        failure = offline ? null : BoardFailure.offline;
      } else {
        failure = BoardFailure.invalidResponse;
      }
    } catch (_) {
      if (_current(operation)) failure = BoardFailure.invalidResponse;
    } finally {
      if (_current(operation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> reloadAfterConflict() => load();

  Future<void> refreshDelta() async {
    final base = snapshot;
    if (base == null || busy || !_current(_epoch)) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final delta = await gateway.delta(
        binding,
        afterSequence: base.boardRevision,
      );
      if (!_current(operation) ||
          delta.afterSequence != base.boardRevision ||
          delta.events.isNotEmpty &&
              delta.events.first.previousHash != base.auditHead) {
        return _stale(operation);
      }
      if (delta.events.isNotEmpty) {
        final value = await gateway.read(binding);
        if (!_current(operation) ||
            value.binding != binding ||
            value.boardRevision != delta.boardRevision ||
            value.auditHead != delta.auditHead) {
          return _stale(operation);
        }
        snapshot = value;
        await cache.write(value, isCurrent: () => _current(operation));
      }
      offline = false;
    } on FamilyBoardException catch (error) {
      if (!_current(operation)) return _stale(operation);
      if (const {
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        offline = true;
      } else if (error.code == 'revision_conflict') {
        failure = BoardFailure.conflict;
      } else {
        failure = BoardFailure.invalidResponse;
      }
    } catch (_) {
      if (_current(operation)) failure = BoardFailure.invalidResponse;
    } finally {
      if (_current(operation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    snapshot = null;
    busy = false;
    offline = false;
    failure = BoardFailure.stale;
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    super.dispose();
  }
}
