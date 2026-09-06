"""Household metadata has a separate wire identity from accounts and resources."""
import importlib

import pytest
from pydantic import ValidationError

from larenor_server.home_resources.models import ResourceRef


def models():
    return importlib.import_module('larenor_server.home_people.models')


def ref(**changes):
    return dict(schemaVersion=1, coreId='a' * 32, homeId='b' * 32,
                kind='person', id='c' * 32) | changes


def record(**changes):
    return dict(ref=ref(), revision=1, aclRevision=2, label='Deniz', order=0,
                permissions=dict(read=True, write=False)) | changes


def test_person_roundtrip_retains_identity_without_creating_account_or_upstream_links():
    m = models()
    person = m.PersonRecord.model_validate(record(label=' Deniz '))
    assert person.label == 'Deniz'
    assert m.PersonRecord.model_validate_json(person.model_dump_json()) == person
    assert person.ref.id == 'c' * 32
    assert set(person.model_dump()) == {'ref', 'revision', 'aclRevision', 'label', 'order', 'permissions'}
    with pytest.raises(ValidationError):
        person.label = 'Changed'


def test_old_resource_decoder_and_person_decoder_do_not_accept_each_others_kind():
    m = models()
    with pytest.raises(ValidationError):
        ResourceRef.model_validate(ref())
    for kind in ('room', 'resource'):
        old = ResourceRef.model_validate(ref(kind=kind))
        with pytest.raises(ValidationError):
            m.PersonRef.model_validate(old.model_dump())
    # Adding people support must not broaden the old resource contract.
    assert ResourceRef.model_validate(ref(kind='room')).kind == 'room'


@pytest.mark.parametrize('field,value', [
    ('schemaVersion', True), ('schemaVersion', 1.0), ('schemaVersion', '1'),
    ('schemaVersion', 2), ('coreId', 'A' * 32), ('homeId', '../another-home'),
    ('id', 'c' * 31), ('id', 123), ('kind', 'user'), ('kind', 'ha_person'),
    ('userId', 'd' * 32), ('entityId', 'person.deniz'), ('url', 'https://fixture.invalid'),
])
def test_person_reference_rejects_coercion_and_implicit_account_or_provider_identity(field, value):
    with pytest.raises(ValidationError):
        models().PersonRef.model_validate(ref(**{field: value}))


@pytest.mark.parametrize('extra', [
    {'id': 'c' * 32}, {'kind': 'person'}, {'userId': 'd' * 32},
    {'role': 'admin'}, {'password': 'fixture-only'}, {'grants': {}},
    {'entityId': 'person.deniz'}, {'birthDate': '2000-01-01'},
    {'health': {}}, {'location': {}}, {'faceEmbedding': []},
])
def test_create_accepts_only_display_metadata_not_identity_authority_or_sensitive_enrichment(extra):
    with pytest.raises(ValidationError):
        models().CreatePersonRequest(label='Deniz', order=0, **extra)


@pytest.mark.parametrize('field,value', [
    ('label', ''), ('label', '  '), ('label', 'x' * 81), ('label', 'x\nadmin'),
    ('label', '\ud800'), ('order', True), ('order', -1), ('order', 10001),
    ('revision', True), ('revision', 0), ('revision', 2**63), ('aclRevision', 1.0),
    ('permissions', {'read': False, 'write': True}),
    ('permissions', {'read': 1, 'write': False}),
    ('permissions', {'read': True, 'write': False, 'admin': True}),
])
def test_person_record_has_bounded_metadata_revisions_and_explicit_permissions(field, value):
    with pytest.raises(ValidationError):
        models().PersonRecord.model_validate(record(**{field: value}))


def test_update_requires_both_current_metadata_and_access_revisions():
    m = models()
    expected = dict(label='Ece', order=10000, expectedRevision=2, expectedAclRevision=3)
    update = m.UpdatePersonRequest.model_validate(expected)
    assert update.model_dump() == expected
    for key in ('expectedRevision', 'expectedAclRevision'):
        missing = dict(expected)
        del missing[key]
        with pytest.raises(ValidationError):
            m.UpdatePersonRequest.model_validate(missing)
        for invalid in (True, '2', 0, 2**63):
            with pytest.raises(ValidationError):
                m.UpdatePersonRequest.model_validate(expected | {key: invalid})


def test_grant_subject_is_an_explicit_login_account_and_target_is_a_person():
    m = models()
    body = m.SetPersonGrantRequest(expectedAclRevision=3, permissions={'read': True, 'write': False})
    grant = m.PersonGrant(subjectId='d' * 32, target=ref(), aclRevision=4, permissions=body.permissions)
    assert grant.subjectId != grant.target.id
    assert m.PersonGrant.model_validate_json(grant.model_dump_json()) == grant
    with pytest.raises(ValidationError):
        m.PersonGrant(subjectId='person.deniz', target=ref(), aclRevision=4, permissions=body.permissions)
    with pytest.raises(ValidationError):
        m.PersonGrant(subjectId='d' * 32, target=ref(kind='room'), aclRevision=4, permissions=body.permissions)


def test_person_pages_are_separate_bounded_and_have_no_hidden_total_or_account_data():
    m = models()
    scope = {key: ref()[key] for key in ('schemaVersion', 'coreId', 'homeId')}
    page = dict(scope=scope, entries=[record()], snapshot='e' * 64, nextAfter=None)
    result = m.PeopleResponse.model_validate(page)
    assert m.PeopleResponse.model_validate_json(result.model_dump_json()) == result
    for change in ({'total': 4}, {'entries': [record()] * 101}, {'snapshot': 'e' * 63},
                   {'nextAfter': '../hidden'}, {'users': []}):
        with pytest.raises(ValidationError):
            m.PeopleResponse.model_validate(page | change)


def test_nested_tampering_is_revalidated_before_a_profile_or_grant_is_used():
    m = models()
    forged = m.PersonRef.model_validate(ref()).model_copy(update={'kind': 'user'})
    with pytest.raises(ValidationError):
        m.PersonRecord.model_validate(record(ref=forged))
    forged = m.PersonRecord.model_validate(record()).model_copy(update={'revision': True})
    with pytest.raises(ValidationError):
        m.PersonResponse(person=forged)


def test_private_stored_profile_has_bounded_explicit_grants_and_no_inferred_links():
    m = models()
    saved = m.StoredPerson(label='Deniz', order=0, grants={'d' * 32: {'read': True, 'write': False}})
    assert m.StoredPerson.model_validate_json(saved.model_dump_json()) == saved
    assert 'dddd' not in repr(saved)
    for changes in ({'grants': {'person.deniz': {'read': True, 'write': False}}},
                    {'grants': {f'{n:032x}': {'read': True, 'write': False} for n in range(129)}},
                    {'grants': {'d' * 32: {'read': False, 'write': False}}},
                    {'accountId': 'd' * 32}, {'source': 'home_assistant'}):
        with pytest.raises(ValidationError):
            m.StoredPerson.model_validate(saved.model_dump() | changes)
