import '../../server/domain/server_models.dart';

Never _invalid() => throw const FormatException('invalid_response');

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _identity(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw)) {
    _invalid();
  }
  return raw;
}

int _integer(
  Object? raw, {
  int minimum = 0,
  int maximum = 9223372036854775807,
}) {
  if (raw is! int || raw < minimum || raw > maximum) _invalid();
  return raw;
}

enum PantryUnit {
  gram('g', 'mass_mg'),
  kilogram('kg', 'mass_mg'),
  milliliter('ml', 'volume_ul'),
  liter('l', 'volume_ul'),
  piece('piece', 'count_milli');

  const PantryUnit(this.wire, this.measure);
  final String wire;
  final String measure;
}

final class PantryAmount {
  const PantryAmount({required this.quantityMillis, required this.unit});

  final int quantityMillis;
  final PantryUnit unit;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'quantityMillis': quantityMillis,
    'unit': unit.wire,
  };

  static PantryAmount? tryParse(String raw, PantryUnit unit) {
    final value = raw.trim().replaceAll(',', '.');
    final match = RegExp(r'^(\d{1,7})(?:\.(\d{1,3}))?$').firstMatch(value);
    if (match == null) return null;
    final whole = int.parse(match.group(1)!);
    final fraction = (match.group(2) ?? '').padRight(3, '0');
    final quantity =
        whole * 1000 + (fraction.isEmpty ? 0 : int.parse(fraction));
    if (quantity < 1 || quantity > 10000000) return null;
    return PantryAmount(quantityMillis: quantity, unit: unit);
  }
}

final class PantryLotDraft {
  const PantryLotDraft({
    required this.id,
    required this.ingredientKey,
    required this.amount,
    this.expiresOn,
  });

  final String id;
  final String ingredientKey;
  final PantryAmount amount;
  final String? expiresOn;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'ingredientKey': ingredientKey,
    'amount': amount.toJson(),
    'expiresOn': expiresOn,
  };
}

final class PantryLotBalance {
  const PantryLotBalance({
    required this.lotId,
    required this.ingredientKey,
    required this.measure,
    required this.remaining,
    required this.expiresOn,
  });

  factory PantryLotBalance.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'lotId',
      'ingredientKey',
      'measure',
      'remaining',
      'expiresOn',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final ingredient = value['ingredientKey'];
    final measure = value['measure'];
    final expiry = value['expiresOn'];
    if (ingredient is! String ||
        ingredient.isEmpty ||
        ingredient.length > 80 ||
        ingredient != ingredient.trim() ||
        ingredient != ingredient.toLowerCase() ||
        !{'mass_mg', 'volume_ul', 'count_milli'}.contains(measure) ||
        expiry != null && expiry is! String ||
        expiry is String && DateTime.tryParse(expiry) == null) {
      _invalid();
    }
    return PantryLotBalance(
      lotId: _identity(value['lotId']),
      ingredientKey: ingredient,
      measure: measure as String,
      remaining: _integer(value['remaining'], minimum: 1, maximum: 10000000000),
      expiresOn: expiry as String?,
    );
  }

  final String lotId;
  final String ingredientKey;
  final String measure;
  final int remaining;
  final String? expiresOn;

  String quantityLabel() => switch (measure) {
    'mass_mg' when remaining >= 1000000 =>
      '${_decimal(remaining / 1000000)} kg',
    'mass_mg' => '${_decimal(remaining / 1000)} g',
    'volume_ul' when remaining >= 1000000 =>
      '${_decimal(remaining / 1000000)} l',
    'volume_ul' => '${_decimal(remaining / 1000)} ml',
    _ => '${_decimal(remaining / 1000)} piece',
  };

  static String _decimal(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value
            .toStringAsFixed(3)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
}

final class PantrySnapshot {
  PantrySnapshot({required this.revision, required List<PantryLotBalance> lots})
    : lots = List.unmodifiable(lots);

  factory PantrySnapshot.fromResponse(
    Object? raw, {
    required ServerContext expected,
  }) {
    final response = _object(raw, {'scope', 'snapshot'});
    _scope(response['scope'], expected);
    return PantrySnapshot.fromJson(response['snapshot']);
  }

  factory PantrySnapshot.fromJson(Object? raw) {
    final value = _object(raw, {'schemaVersion', 'revision', 'lots'});
    if (value['schemaVersion'] != 1 || value['lots'] is! List) _invalid();
    final rawLots = value['lots'] as List;
    if (rawLots.length > 256) _invalid();
    final lots = rawLots.map(PantryLotBalance.fromJson).toList(growable: false);
    if (lots.map((lot) => lot.lotId).toSet().length != lots.length) _invalid();
    return PantrySnapshot(revision: _integer(value['revision']), lots: lots);
  }

  final int revision;
  final List<PantryLotBalance> lots;
}

final class PantryReceipt {
  const PantryReceipt({
    required this.requestId,
    required this.movementId,
    required this.revision,
    required this.kind,
  });

  factory PantryReceipt.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'movementId',
      'revision',
      'kind',
      'allocations',
    });
    final kind = value['kind'];
    final allocations = value['allocations'];
    if (value['schemaVersion'] != 1 ||
        !{'receive', 'consume', 'undo'}.contains(kind) ||
        allocations is! List ||
        allocations.length > 256) {
      _invalid();
    }
    for (final rawAllocation in allocations) {
      final allocation = _object(rawAllocation, {
        'schemaVersion',
        'lotId',
        'quantity',
      });
      if (allocation['schemaVersion'] != 1) _invalid();
      _identity(allocation['lotId']);
      _integer(allocation['quantity'], minimum: 1, maximum: 10000000000);
    }
    return PantryReceipt(
      requestId: _identity(value['requestId']),
      movementId: _identity(value['movementId']),
      revision: _integer(value['revision'], minimum: 1),
      kind: kind as String,
    );
  }

  final String requestId;
  final String movementId;
  final int revision;
  final String kind;
}

final class PantryMutation {
  const PantryMutation({required this.receipt, required this.snapshot});

  factory PantryMutation.fromResponse(
    Object? raw, {
    required ServerContext expected,
    required String expectedRequestId,
    required String expectedKind,
  }) {
    final response = _object(raw, {'scope', 'receipt', 'snapshot'});
    _scope(response['scope'], expected);
    final receipt = PantryReceipt.fromJson(response['receipt']);
    final snapshot = PantrySnapshot.fromJson(response['snapshot']);
    // An idempotent replay keeps its original receipt, while Core returns the
    // current stock snapshot. A later snapshot must not invalidate that receipt
    // or roll the Client back to an earlier balance.
    if (receipt.revision > snapshot.revision ||
        receipt.requestId != expectedRequestId ||
        receipt.kind != expectedKind) {
      _invalid();
    }
    return PantryMutation(receipt: receipt, snapshot: snapshot);
  }

  final PantryReceipt receipt;
  final PantrySnapshot snapshot;
}

void _scope(Object? raw, ServerContext expected) {
  final value = _object(raw, {'schemaVersion', 'coreId', 'homeId'});
  final actual = ServerContext.fromJson({
    'schemaVersion': value['schemaVersion'],
    'coreId': value['coreId'],
    'homeId': value['homeId'],
  });
  if (actual != expected) _invalid();
}
