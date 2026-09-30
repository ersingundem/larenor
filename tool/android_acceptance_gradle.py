"""Private Gradle launcher for hosted Android acceptance runners."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat


class AndroidAcceptanceGradleError(RuntimeError):
    pass


def _executable(name: str) -> str:
    value = shutil.which(name)
    if value is None:
        raise AndroidAcceptanceGradleError(f"required {name} executable is unavailable")
    return value


def _real_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise AndroidAcceptanceGradleError(f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise AndroidAcceptanceGradleError(f"{label} is unavailable") from error
    if resolved != path or not path.is_dir():
        raise AndroidAcceptanceGradleError(f"{label} is not a direct directory")
    return resolved


def _real_file(path: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise AndroidAcceptanceGradleError(f"{label} is unavailable") from error
    if resolved != path or not stat.S_ISREG(metadata.st_mode):
        raise AndroidAcceptanceGradleError(f"{label} is not a direct regular file")
    return resolved


def _exclusive_copy(source: Path, destination: Path) -> None:
    with source.open("rb") as incoming, destination.open("xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    destination.chmod(0o600)


def _resolved_executable(name: str) -> Path:
    try:
        path = Path(_executable(name)).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise AndroidAcceptanceGradleError(
            f"required {name} executable is unavailable"
        ) from error
    path = _real_file(path, f"{name} executable")
    if not os.access(path, os.X_OK):
        raise AndroidAcceptanceGradleError(
            f"required {name} executable is unavailable"
        )
    return path


def materialized_gradle_command(
    workspace: Path,
    *,
    project_android: Path,
) -> list[str]:
    """Materialize Flutter's wrapper beside the project's tracked properties."""
    project_android = _real_directory(project_android, "Android project")
    if not workspace.is_absolute() or os.path.lexists(workspace):
        raise AndroidAcceptanceGradleError(
            "private Gradle launcher workspace must be an absent absolute path"
        )
    _real_directory(workspace.parent, "Gradle launcher parent")
    java = _resolved_executable("java")
    flutter = _resolved_executable("flutter")
    source_wrapper = (
        flutter.parent
        / "cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
    )
    project_properties = project_android / "gradle/wrapper/gradle-wrapper.properties"
    source_wrapper = _real_file(source_wrapper, "Flutter Gradle wrapper artifact")
    project_properties = _real_file(
        project_properties, "project Gradle wrapper properties"
    )

    try:
        workspace.mkdir(mode=0o700)
        workspace.chmod(0o700)
        gradle = workspace / "gradle"
        gradle.mkdir(mode=0o700)
        gradle.chmod(0o700)
        wrapper = gradle / "wrapper"
        wrapper.mkdir(mode=0o700)
        wrapper.chmod(0o700)
        wrapper_jar = wrapper / "gradle-wrapper.jar"
        wrapper_properties = wrapper / "gradle-wrapper.properties"
        _exclusive_copy(source_wrapper, wrapper_jar)
        _exclusive_copy(project_properties, wrapper_properties)
    except OSError as error:
        raise AndroidAcceptanceGradleError(
            "private Gradle launcher could not be materialized"
        ) from error

    return [
        str(java),
        "-Dorg.gradle.appname=gradlew",
        "-classpath",
        str(wrapper_jar),
        "org.gradle.wrapper.GradleWrapperMain",
    ]
