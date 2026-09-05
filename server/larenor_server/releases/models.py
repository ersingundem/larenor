from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
import re
import time
from typing import Callable

from ..errors import ApiError, StartupError

APPLICATION_ID = "com.ersingundem.larenor"
MAX_APK_BYTES = 512 * 1024 * 1024
MAX_METADATA_BYTES = 65536
VERSION = re.compile(r"[1-9][0-9]{0,9}\Z")
UPLOAD_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")
PUBLISH_TOKEN = re.compile(r"lpub_[A-Za-z0-9_-]{43}\Z")
FIELDS = {"schemaVersion", "applicationId", "versionCode", "versionName", "certificateSha256", "apkSha256",
          "sizeBytes", "minSdk", "commit", "downloadPath", "publishedAt", "releaseNotes"}


def version_number(value: object) -> int:
    if type(value) is not int or not 1 <= value <= 2147483647:
        raise ApiError("invalid_request")
    return value


def validate_manifest(raw: object) -> dict:
    if not isinstance(raw, dict) or set(raw) != FIELDS:
        raise ApiError("invalid_request")
    version = version_number(raw["versionCode"])
    if (type(raw["schemaVersion"]) is not int or raw["schemaVersion"] != 1 or raw["applicationId"] != APPLICATION_ID or
            type(raw["sizeBytes"]) is not int or not 1 <= raw["sizeBytes"] <= MAX_APK_BYTES or
            type(raw["minSdk"]) is not int or raw["minSdk"] != 26 or
            raw["downloadPath"] != f"/api/v1/client/releases/{version}/apk"):
        raise ApiError("invalid_request")
    for key, length in (("versionName", 80), ("certificateSha256", 64), ("apkSha256", 64),
                        ("commit", 40), ("publishedAt", 64), ("releaseNotes", 12000)):
        value = raw[key]
        if (not isinstance(value, str) or len(value) > length or
                (key != "releaseNotes" and not value.strip()) or
                any(ord(c) < 32 and c not in "\n\t" or ord(c) == 127 or
                    0xD800 <= ord(c) <= 0xDFFF for c in value)):
            raise ApiError("invalid_request")
    if any(not re.fullmatch(r"[a-fA-F0-9]{64}", raw[key]) for key in ("apkSha256", "certificateSha256")):
        raise ApiError("invalid_request")
    if not re.fullmatch(r"[a-fA-F0-9]{40}", raw["commit"]):
        raise ApiError("invalid_request")
    try:
        when = datetime.fromisoformat(raw["publishedAt"].replace("Z", "+00:00"))
        if when.tzinfo is None or "T" not in raw["publishedAt"]:
            raise ValueError()
    except ValueError:
        raise ApiError("invalid_request") from None
    return {**raw, "certificateSha256": raw["certificateSha256"].lower(),
            "apkSha256": raw["apkSha256"].lower(), "commit": raw["commit"].lower()}


@dataclass(frozen=True)
class ReleaseSettings:
    data_dir: Path
    signer_sha256: str
    publisher_token_file: Path | None = None
    publisher_token: str | None = field(default=None, repr=False)
    max_retained: int = 3
    max_active: int = 1
    max_apk_disk_bytes: int = 2 * 1024 * 1024 * 1024
    upload_ttl_seconds: int = 900
    upload_timeout_seconds: float = 600
    clock: Callable[[], float] = field(default=time.time, repr=False, compare=False)

    def __post_init__(self):
        if (not re.fullmatch(r"[a-f0-9]{64}", self.signer_sha256) or
                not 1 <= self.max_retained <= 10 or not 1 <= self.max_active <= 4 or
                not MAX_APK_BYTES <= self.max_apk_disk_bytes <= 10 * 1024**3 or
                not 1 <= self.upload_ttl_seconds <= 3600 or not 0 < self.upload_timeout_seconds <= 600 or
                self.publisher_token_file is not None and self.publisher_token is not None):
            raise StartupError("invalid_release_settings")
        if self.publisher_token is not None and not PUBLISH_TOKEN.fullmatch(self.publisher_token):
            raise StartupError("invalid_publish_credential")
