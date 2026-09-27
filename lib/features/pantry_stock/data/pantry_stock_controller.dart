import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/pantry_stock_models.dart';
import 'pantry_stock_api.dart';

final class PantryStockController extends ChangeNotifier {
  PantryStockController(this._api, {required this._requestIds});

  final PantryStockAccountApi _api;
  final String Function() _requestIds;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  PantrySnapshot? snapshot;
  String? undoMovementId;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> load() => _run((_) => _api.snapshot());

  Future<bool> receive(PantryLotDraft lot) => _run(
    (revision) => _api.receive(
      requestId: _requestIds(),
      expectedRevision: revision,
      lot: lot,
    ),
  );

  Future<bool> consume(String ingredientKey, PantryAmount amount) => _run(
    (revision) => _api.consume(
      requestId: _requestIds(),
      expectedRevision: revision,
      ingredientKey: ingredientKey,
      amount: amount,
    ),
    rememberUndo: true,
  );

  Future<bool> undo() async {
    final movement = undoMovementId;
    if (movement == null) return false;
    final accepted = await _run(
      (revision) => _api.undo(
        requestId: _requestIds(),
        expectedRevision: revision,
        movementId: movement,
      ),
    );
    if (accepted) undoMovementId = null;
    _emit();
    return accepted;
  }

  Future<bool> _run(
    Future<Object> Function(int revision) action, {
    bool rememberUndo = false,
  }) async {
    if (_disposed || busy) return false;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    _emit();
    try {
      final result = await action(snapshot?.revision ?? 0);
      if (_disposed || operation != _epoch) return false;
      if (result is PantrySnapshot) {
        snapshot = result;
      } else if (result is PantryMutation) {
        snapshot = result.snapshot;
        if (rememberUndo && result.receipt.kind == 'consume') {
          undoMovementId = result.receipt.movementId;
        }
      } else {
        throw const FormatException('invalid_response');
      }
      return true;
    } on LarenorServerException catch (error) {
      if (!_disposed && operation == _epoch) failure = error.code;
      return false;
    } catch (_) {
      if (!_disposed && operation == _epoch) failure = 'invalid_response';
      return false;
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _api.close();
    super.dispose();
  }
}
