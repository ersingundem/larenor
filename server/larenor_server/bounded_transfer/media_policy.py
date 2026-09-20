"""Closed document/media payload validation for product blob uploads."""

import json

from ..errors import ApiError


_ALLOWED_BINARY = frozenset({
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/webp",
    "audio/mpeg",
    "audio/flac",
    "audio/wav",
    "audio/ogg",
    "video/mp4",
    "video/webm",
})
_TEXTUAL = frozenset({"text/plain", "application/json"})


def _reject():
    raise ApiError("invalid_request", 400)


def _media_type(raw: str) -> str:
    if type(raw) is not str or not raw or len(raw) > 128:
        _reject()
    parts = [part.strip().lower() for part in raw.split(";")]
    base = parts[0]
    textual = base in _TEXTUAL
    if len(parts) > 2 or (
        len(parts) == 2
        and (not textual or parts[1] != "charset=utf-8")
    ):
        _reject()
    if not textual and len(parts) != 1:
        _reject()
    if base not in _TEXTUAL and base not in _ALLOWED_BINARY:
        _reject()
    return base


def _starts(content: bytes, expected: bytes, *, offset: int = 0) -> bool:
    return len(content) >= offset + len(expected) and content[offset:offset + len(expected)] == expected


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_json_key")
        value[key] = item
    return value


def _json_constant(_value):
    raise ValueError("invalid_json_constant")


def _text(content: bytes) -> bool:
    try:
        value = content.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return False
    return "\x00" not in value


def _json(content: bytes) -> bool:
    try:
        json.loads(
            content.decode("utf-8", errors="strict"),
            object_pairs_hook=_unique_object,
            parse_constant=_json_constant,
        )
        return True
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError):
        return False


def validate_media_payload(content_type: str, content: bytes) -> None:
    """Reject ambiguous/active types and declared-type payload drift."""
    if type(content) is not bytes or not 1 <= len(content) <= 256 * 1024:
        _reject()
    media_type = _media_type(content_type)
    valid = {
        "text/plain": lambda: _text(content),
        "application/json": lambda: _json(content),
        "application/pdf": lambda: _starts(content, b"%PDF-"),
        "image/png": lambda: _starts(content, b"\x89PNG\r\n\x1a\n"),
        "image/jpeg": lambda: (
            _starts(content, b"\xff\xd8\xff")
            and len(content) >= 5
            and content[-2:] == b"\xff\xd9"
        ),
        "image/webp": lambda: (
            _starts(content, b"RIFF")
            and _starts(content, b"WEBP", offset=8)
        ),
        "audio/mpeg": lambda: (
            _starts(content, b"ID3")
            or len(content) >= 2 and content[0] == 0xFF and content[1] & 0xE0 == 0xE0
        ),
        "audio/flac": lambda: _starts(content, b"fLaC"),
        "audio/wav": lambda: (
            _starts(content, b"RIFF")
            and _starts(content, b"WAVE", offset=8)
        ),
        "audio/ogg": lambda: _starts(content, b"OggS"),
        "video/mp4": lambda: _starts(content, b"ftyp", offset=4),
        "video/webm": lambda: _starts(content, b"\x1a\x45\xdf\xa3"),
    }[media_type]()
    if not valid:
        _reject()
