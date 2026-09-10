"""Exact upstream qBittorrent 5.2 API-key shape."""

from larenor_server.plugins.qbittorrent_api_key import (
    generate_qbittorrent_api_key,
    is_qbittorrent_api_key,
)


def test_generated_key_has_the_exact_upstream_shape_and_entropy(monkeypatch):
    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_api_key.secrets.token_urlsafe',
        lambda count: 'A_-b' * 7 if count == 21 else (_ for _ in ()).throw(
            AssertionError('unexpected entropy size')))
    value = generate_qbittorrent_api_key()
    assert value == 'qbt_' + 'A_-b' * 7
    assert is_qbittorrent_api_key(value)


def test_api_key_contract_rejects_general_tokens_and_non_strings():
    for value in ('x' * 32, 'qbt_' + 'x' * 27, 'qbt_' + 'x' * 29,
                  'qbt_' + ':' * 28, b'qbt_' + b'x' * 28, True, None):
        assert not is_qbittorrent_api_key(value)
