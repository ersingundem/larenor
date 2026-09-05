from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Protocol

from ..errors import ApiError

APKSIG_VERSION = "9.1.0"
# Official Google Maven artifact, not an arbitrary jar supplied by a request.
APKSIG_SHA256 = "562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201"


class ApkVerifier(Protocol):
    def verify(self, path: Path) -> dict: ...


@dataclass(frozen=True)
class JavaApkVerifier:
    java: Path
    jar: Path
    classes: Path
    timeout_seconds: float = 90

    def verify(self, path: Path) -> dict:
        try:
            if (not self.java.is_absolute() or not self.java.is_file() or not self.jar.is_absolute() or
                    not self.classes.is_absolute() or self.jar.is_symlink() or
                    self.jar.stat().st_size > 4 * 1024 * 1024 or
                    hashlib.sha256(self.jar.read_bytes()).hexdigest() != APKSIG_SHA256):
                raise ApiError("release_verifier_unavailable", 503)
            result = subprocess.run([str(self.java), "-Xmx256m", "-cp", f"{self.jar}:{self.classes}",
                                     "org.larenor.updates.VerifyApk", str(path)],
                                    capture_output=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=self.timeout_seconds, check=False,
                                    env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
            if result.returncode != 0:
                raise ApiError("release_verification_failed" if result.returncode == 3 else "release_verifier_unavailable",
                               422 if result.returncode == 3 else 503)
            if len(result.stdout) > 4096:
                raise ValueError()
            value = json.loads(result.stdout)
            if (not isinstance(value, dict) or set(value) != {"schemaVersion", "verified", "applicationId", "versionCode",
                    "versionName", "certificateSha256", "minSdk", "debuggable"} or
                    value["schemaVersion"] != 1 or value["verified"] is not True or value["debuggable"] is not False):
                raise ValueError()
            return value
        except ApiError:
            raise
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise ApiError("release_verifier_unavailable", 503) from None


def compare_verified(expected: dict, observed: dict, pinned: str) -> None:
    if (observed.get("verified") is not True or observed.get("debuggable") is not False or
            type(observed.get("versionCode")) is not int or type(observed.get("minSdk")) is not int or
            observed.get("certificateSha256") != pinned or expected["certificateSha256"] != pinned or
            any(observed.get(key) != expected[key] for key in ("applicationId", "versionCode", "versionName", "minSdk"))):
        raise ApiError("release_verification_failed", 422)
