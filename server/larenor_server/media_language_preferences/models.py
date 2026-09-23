import re
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


PreferenceRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]
Language = Annotated[str, Field(min_length=2, max_length=7)]


def language(value, *, allow_off=False):
    if value is None:
        return None
    if type(value) is not str:
        raise ValueError("invalid_language")
    if allow_off and value == "off":
        return value
    if re.fullmatch(r"[a-z]{2,3}(?:-[a-z]{2}|-[0-9]{3})?", value) is None:
        raise ValueError("invalid_language")
    return value


class MediaLanguagePreferenceFields(FrozenModel):
    audioLanguage: Language | None
    subtitleLanguage: Language | Literal["off"] | None

    @field_validator("audioLanguage", mode="before")
    @classmethod
    def audio_language(cls, value):
        return language(value)

    @field_validator("subtitleLanguage", mode="before")
    @classmethod
    def subtitle_language(cls, value):
        return language(value, allow_off=True)

    @model_validator(mode="after")
    def not_empty(self):
        if self.audioLanguage is None and self.subtitleLanguage is None:
            raise ValueError("empty_preference")
        return self


class StoredMediaLanguagePreference(MediaLanguagePreferenceFields):
    pass


class PutMediaLanguagePreference(MediaLanguagePreferenceFields):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedAccountRevision: Revision
    expectedRevision: PreferenceRevision

    @field_validator(
        "schemaVersion",
        "expectedAccountRevision",
        "expectedRevision",
        mode="before",
    )
    @classmethod
    def exact_integer(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_integer")
        return value


class MediaLanguagePreferenceRef(HomeScope):
    accountId: Identity
    kind: Literal["media_language_preferences"]


class MediaLanguagePreference(MediaLanguagePreferenceFields):
    schemaVersion: Literal[1]
    ref: MediaLanguagePreferenceRef
    revision: Revision


class MediaLanguagePreferenceAuthority(HomeScope):
    accountId: Identity
    sessionFamilyId: Identity
    accountRevision: Revision
    preferenceRevision: PreferenceRevision


class MediaLanguagePreferenceResponse(FrozenModel):
    schemaVersion: Literal[1]
    authority: MediaLanguagePreferenceAuthority
    preference: MediaLanguagePreference | None
