"""Versioned home resource data must never become an authority by coercion."""
import importlib

import pytest
from pydantic import ValidationError


def models():
    return importlib.import_module('larenor_server.home_resources.models')


def scope():
    return dict(schemaVersion=1, coreId='a' * 32, homeId='b' * 32)


def reference(**changes):
    return dict(**scope(), kind='room', id='c' * 32, **changes)


def test_contract_roundtrip_is_frozen_and_has_no_account_or_provider_fields():
    m = models()
    ref = m.ResourceRef(**reference())
    record = m.RegistryRecord(ref=ref, revision=1, aclRevision=1, label=' Salon ', order=0,
                              permissions=m.Permissions(read=True, write=False))
    assert record.label == 'Salon'
    assert m.RegistryRecord.model_validate_json(record.model_dump_json()) == record
    assert set(record.model_dump()) == {'ref', 'revision', 'aclRevision', 'label', 'order', 'permissions'}
    with pytest.raises(ValidationError):
        record.label = 'Changed'


@pytest.mark.parametrize('field,value', [
    ('schemaVersion', True), ('schemaVersion', 1.0), ('schemaVersion', 2),
    ('coreId', 'A' * 32), ('homeId', 'b' * 31), ('id', '../secret'),
    ('kind', 'vault'), ('kind', 'user'), ('kind', 'session'), ('kind', 'person'),
    ('url', 'https://fixture.invalid'), ('ownerId', 'd' * 32), ('credentials', {}),
])
def test_ref_rejects_coercion_unknown_kinds_and_private_fields(field, value):
    data = reference(); data[field] = value
    with pytest.raises(ValidationError):
        models().ResourceRef(**data)


@pytest.mark.parametrize('data', [dict(read=1, write=False), dict(read=True, write='false'),
                                dict(read=False, write=True), dict(read=True, write=False, admin=True)])
def test_permissions_are_explicit_and_write_requires_read(data):
    with pytest.raises(ValidationError):
        models().Permissions(**data)


@pytest.mark.parametrize('field,value', [('label', ''), ('label', '  '), ('label', 'x' * 81),
    ('label', 'line\nsecond'), ('label', '\ud800'), ('order', True), ('order', -1),
    ('order', 10001), ('revision', True), ('revision', 0), ('aclRevision', 1.0)])
def test_record_rejects_unbounded_or_noncanonical_metadata(field, value):
    m = models(); data = dict(ref=reference(), revision=1, aclRevision=1, label='Oda', order=0,
                             permissions=dict(read=True, write=False)); data[field] = value
    with pytest.raises(ValidationError):
        m.RegistryRecord(**data)


def test_nested_copy_tampering_is_revalidated():
    m = models(); ref = m.ResourceRef(**reference()).model_copy(update={'kind': 'vault'})
    with pytest.raises(ValidationError):
        m.RegistryRecord(ref=ref, revision=1, aclRevision=1, label='Oda', order=0,
                         permissions=m.Permissions(read=True, write=False))
