import 'package:flutter/foundation.dart';

import '../domain/ingredient_deduction.dart';

abstract interface class IngredientDeductionGateway {
  Future<IngredientDeductionReceipt> commit(IngredientDeductionPreview preview);
  Future<IngredientDeductionReceipt?> receipt(String idempotencyKey);
}

enum IngredientDeductionFailure {
  unavailable,
  uncertain,
  staleAuthority,
  invalidReceipt,
}

final class IngredientDeductionController extends ChangeNotifier {
  IngredientDeductionController({
    required this.gateway,
    required this.preview,
    required this.isCurrent,
  });

  final IngredientDeductionGateway gateway;
  final IngredientDeductionPreview preview;
  final bool Function() isCurrent;
  IngredientDeductionReceipt? receipt;
  IngredientDeductionFailure? failure;
  bool busy = false;
  bool _retired = false;
  int _epoch = 0;

  bool _current() {
    if (_retired) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _matches(IngredientDeductionReceipt value) {
    if (value.idempotencyKey != preview.idempotencyKey ||
        value.accountId != preview.accountId ||
        value.pantryRevision != preview.expectedPantryRevision + 1 ||
        value.applied.length != preview.items.length) {
      return false;
    }
    for (var index = 0; index < preview.items.length; index++) {
      final expected = preview.items[index];
      final actual = value.applied[index];
      if (actual.stockItemId != expected.stockItemId ||
          actual.quantityMicros != expected.quantityMicros) {
        return false;
      }
    }
    return true;
  }

  bool _denyStale() {
    receipt = null;
    failure = IngredientDeductionFailure.staleAuthority;
    return false;
  }

  Future<bool> confirm() async {
    if (!_current()) return _denyStale();
    if (receipt != null) return true;
    if (busy || failure == IngredientDeductionFailure.uncertain) {
      return false;
    }
    return _perform(() => gateway.commit(preview), uncertainOnFailure: true);
  }

  /// The only operation allowed after a lost acknowledgement. It reads the
  /// existing receipt by idempotency key and never repeats the stock command.
  Future<bool> reconcile() async {
    if (!_current()) return _denyStale();
    if (receipt != null) return true;
    if (busy) return false;
    return _perform(() async {
      final value = await gateway.receipt(preview.idempotencyKey);
      if (value == null) throw StateError('receipt_not_found');
      return value;
    }, uncertainOnFailure: false);
  }

  Future<bool> _perform(
    Future<IngredientDeductionReceipt> Function() operation, {
    required bool uncertainOnFailure,
  }) async {
    final epoch = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final value = await operation();
      if (epoch != _epoch || !_current()) {
        return _denyStale();
      }
      if (!_matches(value)) {
        failure = IngredientDeductionFailure.invalidReceipt;
        return false;
      }
      receipt = value;
      failure = null;
      return true;
    } catch (_) {
      if (epoch != _epoch || !_current()) {
        _denyStale();
      } else {
        failure = uncertainOnFailure
            ? IngredientDeductionFailure.uncertain
            : IngredientDeductionFailure.unavailable;
      }
      return false;
    } finally {
      if (epoch == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    receipt = null;
    failure = IngredientDeductionFailure.staleAuthority;
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
