from concurrent.futures import ThreadPoolExecutor

import pytest

from larenor_server.pantry_stock.ledger import PantryConflict, PantryLedger
from larenor_server.pantry_stock.models import StockAmount, StockLot


def ident(char):
    return char * 32


def lot(char, amount, unit, expiry):
    return StockLot(
        schemaVersion=1,
        id=ident(char),
        ingredientKey='mercimek',
        amount=StockAmount(schemaVersion=1, quantityMillis=amount, unit=unit),
        expiresOn=expiry,
    )


def test_units_lots_and_expiry_are_canonical_and_bounded():
    assert StockAmount(schemaVersion=1, quantityMillis=1500, unit='g').normalized == (
        'mass_mg', 1500)
    assert StockAmount(schemaVersion=1, quantityMillis=2, unit='kg').normalized == (
        'mass_mg', 2000)
    assert StockAmount(schemaVersion=1, quantityMillis=2500, unit='ml').normalized == (
        'volume_ul', 2500)
    assert StockAmount(schemaVersion=1, quantityMillis=3, unit='l').normalized == (
        'volume_ul', 3000)
    assert StockAmount(schemaVersion=1, quantityMillis=1500, unit='piece').normalized == (
        'count_milli', 1500)

    for invalid in (
        {'schemaVersion': 2, 'quantityMillis': 1, 'unit': 'g'},
        {'schemaVersion': 1, 'quantityMillis': 0, 'unit': 'g'},
        {'schemaVersion': 1, 'quantityMillis': 1.5, 'unit': 'g'},
        {'schemaVersion': 1, 'quantityMillis': 1, 'unit': 'cup'},
    ):
        with pytest.raises(ValueError):
            StockAmount.model_validate(invalid)
    with pytest.raises(ValueError):
        lot('a', 1, 'g', '2026-02-30')
    with pytest.raises(ValueError):
        lot('a', 1, 'g', '21-09-2026')


def test_consume_is_atomic_earliest_expiry_and_stale_race_has_one_winner():
    ledger = PantryLedger(max_lots=8, max_receipts=32)
    ledger.receive(
        request_id=ident('1'), expected_revision=0,
        lot=lot('a', 1000, 'g', '2026-09-30'))
    ledger.receive(
        request_id=ident('2'), expected_revision=1,
        lot=lot('b', 500, 'g', '2026-09-25'))

    def consume(request_id):
        try:
            return ledger.consume(
                request_id=request_id,
                expected_revision=2,
                ingredient_key='mercimek',
                amount=StockAmount(
                    schemaVersion=1, quantityMillis=600, unit='g'),
            )
        except PantryConflict as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(consume, (ident('3'), ident('4'))))
    receipt = next(value for value in results if not isinstance(value, str))
    assert results.count('revision_conflict') == 1
    assert receipt.revision == 3
    assert [(a.lotId, a.quantity) for a in receipt.allocations] == [
        (ident('b'), 500), (ident('a'), 100)]
    assert ledger.snapshot().lots[0].remaining == 900
    before = ledger.snapshot()
    with pytest.raises(PantryConflict, match='insufficient_stock'):
        ledger.consume(
            request_id=ident('5'), expected_revision=3,
            ingredient_key='mercimek',
            amount=StockAmount(
                schemaVersion=1, quantityMillis=901, unit='g'))
    assert ledger.snapshot() == before


def test_retry_and_undo_are_exact_idempotent_and_never_double_restore():
    ledger = PantryLedger(max_lots=4, max_receipts=8)
    received = ledger.receive(
        request_id=ident('1'), expected_revision=0,
        lot=lot('a', 1000, 'g', '2026-09-30'))
    request = dict(
        request_id=ident('2'), expected_revision=received.revision,
        ingredient_key='mercimek',
        amount=StockAmount(schemaVersion=1, quantityMillis=400, unit='g'),
    )
    consumed = ledger.consume(**request)
    assert ledger.consume(**request) == consumed
    with pytest.raises(PantryConflict, match='idempotency_conflict'):
        ledger.consume(**{**request, 'amount': StockAmount(
            schemaVersion=1, quantityMillis=401, unit='g')})

    undo = ledger.undo(
        request_id=ident('3'), expected_revision=consumed.revision,
        movement_id=consumed.movementId)
    assert ledger.undo(
        request_id=ident('3'), expected_revision=consumed.revision,
        movement_id=consumed.movementId) == undo
    assert sum(value.remaining for value in ledger.snapshot().lots) == 1000
    with pytest.raises(PantryConflict, match='already_reverted'):
        ledger.undo(
            request_id=ident('4'), expected_revision=undo.revision,
            movement_id=consumed.movementId)
