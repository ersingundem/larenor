import re
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


Language = Annotated[str, Field(min_length=2, max_length=32)]


def _language(value, *, off=False):
    if value is None:
        return None
    if type(value) is not str:
        raise ValueError("invalid_language")
    if off and value == "off":
        return value
    if re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,2}", value) is None:
        raise ValueError("invalid_language")
    return value


class JellyfinPreferenceAuthority(HomeScope):
    schemaVersion: Literal[1]
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity


class JellyfinPreferenceRef(HomeScope):
    accountId: Identity
    kind: Literal["jellyfin_track_preferences"]


class JellyfinTrackPreference(FrozenModel):
    schemaVersion: Literal[1]
    ref: JellyfinPreferenceRef
    revision: Revision
    audioLanguage: Language | None
    subtitleLanguage: Language | Literal["off"] | None

    @field_validator("audioLanguage", mode="before")
    @classmethod
    def audio_language(cls, value):
        return _language(value)

    @field_validator("subtitleLanguage", mode="before")
    @classmethod
    def subtitle_language(cls, value):
        return _language(value, off=True)


class JellyfinTrackPreferenceResponse(FrozenModel):
    schemaVersion: Literal[1]
    authority: JellyfinPreferenceAuthority
    preference: JellyfinTrackPreference | None


class PutJellyfinTrackPreference(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    audioLanguage: Language | None
    subtitleLanguage: Language | Literal["off"] | None

    @field_validator("schemaVersion", "expectedRevision", mode="before")
    @classmethod
    def exact_integer(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_integer")
        return value

    _audio = field_validator("audioLanguage", mode="before")(
        JellyfinTrackPreference.audio_language.__func__
    )
    _subtitle = field_validator("subtitleLanguage", mode="before")(
        JellyfinTrackPreference.subtitle_language.__func__
    )

    @model_validator(mode="after")
    def at_least_one_preference(self):
        if self.audioLanguage is None and self.subtitleLanguage is None:
            raise ValueError("empty_preference")
        return self
