import hashlib
import json
import threading
from dataclasses import dataclass
from datetime import date

from .models import (
    LotBalance,
    StockAllocation,
    StockAmount,
    StockLot,
    StockReceipt,
    StockSnapshot,
)


class PantryConflict(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass
class _Lot:
    value: StockLot
    measure: str
    remaining: int
    sequence: int


@dataclass
class _Movement:
    allocations: tuple[StockAllocation, ...]
    reverted: bool = False


class PantryLedger:
    """Thread-safe reducer foundation; persistence and HTTP land separately."""

    def __init__(self, *, max_lots=256, max_receipts=4096):
        if (type(max_lots) is not int or type(max_receipts) is not int or
                not 1 <= max_lots <= 4096 or
                not 1 <= max_receipts <= 10000):
            raise ValueError('invalid_limits')
        self._max_lots, self._max_receipts = max_lots, max_receipts
        self._lock = threading.RLock()
        self._revision = 0
        self._sequence = 0
        self._lots: dict[str, _Lot] = {}
        self._movements: dict[str, _Movement] = {}
        self._receipts: dict[str, tuple[str, StockReceipt]] = {}

    @staticmethod
    def _identity(value):
        if (not isinstance(value, str) or len(value) != 32 or
                any(char not in '0123456789abcdef' for char in value)):
            raise PantryConflict('invalid_request')
        return value

    @staticmethod
    def _digest(kind, value):
        encoded = json.dumps(
            {'kind': kind, **value}, sort_keys=True,
            separators=(',', ':'), ensure_ascii=False,
        ).encode('utf-8')
        return hashlib.sha256(encoded).hexdigest()

    @staticmethod
    def _movement(request_id, kind):
        return hashlib.sha256(
            f'larenor-f32-{kind}-v1\0{request_id}'.encode('ascii')
        ).hexdigest()[:32]

    def _replay(self, request_id, digest):
        receipt = self._receipts.get(request_id)
        if receipt is None:
            return None
        if receipt[0] != digest:
            raise PantryConflict('idempotency_conflict')
        return receipt[1]

    def _begin(self, request_id, expected_revision, digest):
        self._identity(request_id)
        replay = self._replay(request_id, digest)
        if replay is not None:
            return replay
        if (type(expected_revision) is not int or expected_revision < 0 or
                expected_revision != self._revision):
            raise PantryConflict('revision_conflict')
        if self._revision >= 2**63 - 1:
            raise PantryConflict('revision_conflict')
        if len(self._receipts) >= self._max_receipts:
            raise PantryConflict('receipt_capacity')
        return None

    def _finish(self, request_id, digest, kind, allocations=()):
        self._revision += 1
        movement_id = self._movement(request_id, kind)
        receipt = StockReceipt(
            schemaVersion=1, requestId=request_id, movementId=movement_id,
            revision=self._revision, kind=kind, allocations=allocations,
        )
        self._receipts[request_id] = digest, receipt
        return receipt

    def receive(self, *, request_id, expected_revision, lot):
        lot = StockLot.model_validate(lot)
        digest = self._digest('receive', {
            'expectedRevision': expected_revision,
            'lot': lot.model_dump(mode='json'),
        })
        with self._lock:
            replay = self._begin(request_id, expected_revision, digest)
            if replay is not None:
                return replay
            if lot.id in self._lots:
                raise PantryConflict('duplicate_lot')
            if len(self._lots) >= self._max_lots:
                raise PantryConflict('lot_capacity')
            measure, quantity = lot.amount.normalized
            self._sequence += 1
            self._lots[lot.id] = _Lot(lot, measure, quantity, self._sequence)
            return self._finish(request_id, digest, 'receive')

    def consume(self, *, request_id, expected_revision, ingredient_key, amount):
        amount = StockAmount.model_validate(amount)
        if (not isinstance(ingredient_key, str) or ingredient_key == '' or
                ingredient_key != ingredient_key.strip() or
                ingredient_key != ingredient_key.lower() or
                len(ingredient_key) > 80 or
                any(ord(char) < 32 or ord(char) == 127
                    for char in ingredient_key)):
            raise PantryConflict('invalid_request')
        measure, quantity = amount.normalized
        digest = self._digest('consume', {
            'expectedRevision': expected_revision,
            'ingredientKey': ingredient_key,
            'measure': measure,
            'quantity': quantity,
        })
        with self._lock:
            replay = self._begin(request_id, expected_revision, digest)
            if replay is not None:
                return replay
            candidates = [
                value for value in self._lots.values()
                if value.value.ingredientKey == ingredient_key and
                value.measure == measure and value.remaining > 0
            ]
            candidates.sort(key=lambda value: (
                value.value.expiresOn is None,
                date.max if value.value.expiresOn is None else
                date.fromisoformat(value.value.expiresOn),
                value.sequence,
            ))
            if sum(value.remaining for value in candidates) < quantity:
                raise PantryConflict('insufficient_stock')
            remaining = quantity
            allocations = []
            for candidate in candidates:
                if remaining == 0:
                    break
                taken = min(candidate.remaining, remaining)
                allocations.append(StockAllocation(
                    schemaVersion=1, lotId=candidate.value.id,
                    quantity=taken))
                remaining -= taken
            for allocation in allocations:
                self._lots[allocation.lotId].remaining -= allocation.quantity
            receipt = self._finish(
                request_id, digest, 'consume', tuple(allocations))
            self._movements[receipt.movementId] = _Movement(tuple(allocations))
            return receipt

    def undo(self, *, request_id, expected_revision, movement_id):
        self._identity(movement_id)
        digest = self._digest('undo', {
            'expectedRevision': expected_revision,
            'movementId': movement_id,
        })
        with self._lock:
            replay = self._begin(request_id, expected_revision, digest)
            if replay is not None:
                return replay
            movement = self._movements.get(movement_id)
            if movement is None:
                raise PantryConflict('movement_not_found')
            if movement.reverted:
                raise PantryConflict('already_reverted')
            if any(value.lotId not in self._lots for value in movement.allocations):
                raise PantryConflict('lot_missing')
            for allocation in movement.allocations:
                self._lots[allocation.lotId].remaining += allocation.quantity
            movement.reverted = True
            return self._finish(
                request_id, digest, 'undo', movement.allocations)

    def snapshot(self):
        with self._lock:
            lots = tuple(
                LotBalance(
                    schemaVersion=1, lotId=value.value.id,
                    ingredientKey=value.value.ingredientKey,
                    measure=value.measure, remaining=value.remaining,
                    expiresOn=value.value.expiresOn,
                )
                for value in sorted(
                    self._lots.values(), key=lambda item: item.sequence)
                if value.remaining > 0
            )
            return StockSnapshot(
                schemaVersion=1, revision=self._revision, lots=lots)

    def export_state(self):
        """Return the exact bounded reducer state for authenticated storage."""
        with self._lock:
            return {
                'schemaVersion': 1,
                'revision': self._revision,
                'sequence': self._sequence,
                'lots': [
                    {
                        'lot': value.value.model_dump(mode='json'),
                        'measure': value.measure,
                        'remaining': value.remaining,
                        'sequence': value.sequence,
                    }
                    for _, value in sorted(self._lots.items())
                ],
                'movements': [
                    {
                        'movementId': key,
                        'allocations': [item.model_dump(mode='json')
                                        for item in value.allocations],
                        'reverted': value.reverted,
                    }
                    for key, value in sorted(self._movements.items())
                ],
                'receipts': [
                    {
                        'requestId': key,
                        'digest': value[0],
                        'receipt': value[1].model_dump(mode='json'),
                    }
                    for key, value in sorted(self._receipts.items())
                ],
            }

    @classmethod
    def from_state(cls, value, *, max_lots=256, max_receipts=4096):
        """Rebuild a reducer only from its exact authenticated state."""
        if (type(value) is not dict or set(value) != {
                'schemaVersion', 'revision', 'sequence', 'lots',
                'movements', 'receipts'} or value['schemaVersion'] != 1 or
                type(value['revision']) is not int or
                not 0 <= value['revision'] <= 2**63 - 1 or
                type(value['sequence']) is not int or
                not 0 <= value['sequence'] <= max_lots or
                type(value['lots']) is not list or
                len(value['lots']) > max_lots or
                type(value['movements']) is not list or
                len(value['movements']) > max_receipts or
                type(value['receipts']) is not list or
                len(value['receipts']) > max_receipts):
            raise ValueError('invalid_pantry_state')
        ledger = cls(max_lots=max_lots, max_receipts=max_receipts)
        seen_sequences = set()
        for raw in value['lots']:
            if type(raw) is not dict or set(raw) != {
                    'lot', 'measure', 'remaining', 'sequence'}:
                raise ValueError('invalid_pantry_state')
            lot = StockLot.model_validate(raw['lot'])
            measure, original = lot.amount.normalized
            if (raw['measure'] != measure or type(raw['remaining']) is not int
                    or not 0 <= raw['remaining'] <= original
                    or type(raw['sequence']) is not int
                    or not 1 <= raw['sequence'] <= value['sequence']
                    or raw['sequence'] in seen_sequences
                    or lot.id in ledger._lots):
                raise ValueError('invalid_pantry_state')
            seen_sequences.add(raw['sequence'])
            ledger._lots[lot.id] = _Lot(
                lot, measure, raw['remaining'], raw['sequence'])
        for raw in value['movements']:
            if (type(raw) is not dict or set(raw) != {
                    'movementId', 'allocations', 'reverted'} or
                    type(raw['reverted']) is not bool or
                    type(raw['allocations']) is not list or
                    not 1 <= len(raw['allocations']) <= max_lots):
                raise ValueError('invalid_pantry_state')
            try:
                movement_id = ledger._identity(raw['movementId'])
            except PantryConflict:
                raise ValueError('invalid_pantry_state') from None
            allocations = tuple(
                StockAllocation.model_validate(item)
                for item in raw['allocations'])
            if (movement_id in ledger._movements or
                    any(item.lotId not in ledger._lots
                        for item in allocations)):
                raise ValueError('invalid_pantry_state')
            ledger._movements[movement_id] = _Movement(
                allocations, raw['reverted'])
        revisions = set()
        for raw in value['receipts']:
            if (type(raw) is not dict or set(raw) != {
                    'requestId', 'digest', 'receipt'} or
                    type(raw['digest']) is not str or
                    len(raw['digest']) != 64 or
                    any(char not in '0123456789abcdef'
                        for char in raw['digest'])):
                raise ValueError('invalid_pantry_state')
            try:
                request_id = ledger._identity(raw['requestId'])
            except PantryConflict:
                raise ValueError('invalid_pantry_state') from None
            raw_receipt = raw['receipt']
            if (type(raw_receipt) is not dict or
                    type(raw_receipt.get('allocations')) is not list):
                raise ValueError('invalid_pantry_state')
            receipt = StockReceipt.model_validate({
                **raw_receipt,
                'allocations': tuple(raw_receipt['allocations']),
            })
            if (request_id != receipt.requestId or
                    request_id in ledger._receipts or
                    receipt.revision in revisions or
                    receipt.revision > value['revision']):
                raise ValueError('invalid_pantry_state')
            revisions.add(receipt.revision)
            ledger._receipts[request_id] = raw['digest'], receipt
        consume_movements = {
            receipt.movementId: receipt.allocations
            for _, receipt in ledger._receipts.values()
            if receipt.kind == 'consume'
        }
        if (set(consume_movements) != set(ledger._movements) or
                any(consume_movements[key] != movement.allocations
                    for key, movement in ledger._movements.items())):
            raise ValueError('invalid_pantry_state')
        if (len(revisions) != value['revision'] or
                revisions != set(range(1, value['revision'] + 1))):
            raise ValueError('invalid_pantry_state')
        ledger._revision = value['revision']
        ledger._sequence = value['sequence']
        return ledger
