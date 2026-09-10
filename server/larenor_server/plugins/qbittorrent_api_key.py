"""Exact qBittorrent 5.2 API-key contract."""

import re
import secrets


QB_API_KEY_PATTERN = r'^qbt_[A-Za-z0-9_-]{28}$'
_API_KEY = re.compile(QB_API_KEY_PATTERN)


def is_qbittorrent_api_key(value):
    return type(value) is str and _API_KEY.fullmatch(value) is not None


def generate_qbittorrent_api_key():
    # 21 random bytes encode to exactly 28 unpadded base64url characters.
    value = 'qbt_' + secrets.token_urlsafe(21)
    if not is_qbittorrent_api_key(value):
        raise RuntimeError('qbittorrent_api_key_generation_failed')
    return value
