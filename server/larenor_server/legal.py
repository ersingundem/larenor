"""Public source and licensing metadata; contains no deployment secrets."""

from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
import os
import re
from urllib.parse import urlsplit

from pydantic import BaseModel

from .errors import StartupError


def server_version() -> str:
    try:
        return version("larenor-server")
    except PackageNotFoundError:
        return "0.1.0"


class SourceResponse(BaseModel):
    service: str = "larenor-server"
    version: str
    license: str = "AGPL-3.0-only"
    sourceUrl: str
    sourceRevision: str | None
    licenseUrl: str


@dataclass(frozen=True)
class SourceInformation:
    source_url: str = "https://github.com/ersingundem/larenor"
    source_revision: str | None = None
    license_url: str = "https://github.com/ersingundem/larenor/blob/main/LICENSE"

    def __post_init__(self):
        for value in (self.source_url, self.license_url):
            try:
                url = urlsplit(value)
                valid = (len(value) <= 2048 and url.scheme == "https"
                         and url.hostname and not url.username and not url.password
                         and not url.query and not url.fragment
                         and not any(char.isspace() or ord(char) < 32 for char in value)
                         and url.port in (None, 443))
            except ValueError:
                valid = False
            if not valid:
                raise StartupError("source_url_invalid")
        if self.source_revision is not None and not re.fullmatch(r"[0-9a-f]{40}", self.source_revision):
            raise StartupError("source_revision_invalid")

    @classmethod
    def from_environment(cls):
        return cls(
            source_url=os.environ.get("LARENOR_SOURCE_URL", cls.source_url),
            source_revision=os.environ.get("LARENOR_SOURCE_REVISION") or None,
            license_url=os.environ.get("LARENOR_LICENSE_URL", cls.license_url),
        )

    def response(self) -> SourceResponse:
        return SourceResponse(
            version=server_version(), sourceUrl=self.source_url,
            sourceRevision=self.source_revision, licenseUrl=self.license_url,
        )
