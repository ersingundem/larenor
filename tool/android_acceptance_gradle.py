"""Private Gradle launcher for hosted Android acceptance runners."""

from __future__ import annotations

from pathlib import Path
import shutil


class AndroidAcceptanceGradleError(RuntimeError):
    pass


def _executable(name: str) -> str:
    value = shutil.which(name)
    if value is None:
        raise AndroidAcceptanceGradleError(f"required {name} executable is unavailable")
    return value


def materialized_gradle_command(
    workspace: Path,
    *,
    project_android: Path,
) -> list[str]:
    """Materialize Flutter's wrapper beside the project's tracked properties."""
    java = _executable("java")
    flutter = Path(_executable("flutter")).resolve(strict=True)
    source_wrapper = (
        flutter.parent
        / "cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
    )
    project_properties = project_android / "gradle/wrapper/gradle-wrapper.properties"
    if not source_wrapper.is_file() or source_wrapper.is_symlink():
        raise AndroidAcceptanceGradleError(
            "Flutter Gradle wrapper artifact is unavailable"
        )
    if not project_properties.is_file() or project_properties.is_symlink():
        raise AndroidAcceptanceGradleError(
            "project Gradle wrapper properties are unavailable"
        )

    wrapper = workspace / "gradle/wrapper"
    try:
        wrapper.mkdir(parents=True, mode=0o700)
        wrapper_jar = wrapper / "gradle-wrapper.jar"
        wrapper_properties = wrapper / "gradle-wrapper.properties"
        shutil.copyfile(source_wrapper, wrapper_jar)
        shutil.copyfile(project_properties, wrapper_properties)
        wrapper_jar.chmod(0o600)
        wrapper_properties.chmod(0o600)
    except OSError as error:
        raise AndroidAcceptanceGradleError(
            "private Gradle launcher could not be materialized"
        ) from error

    return [
        java,
        "-Dorg.gradle.appname=gradlew",
        "-classpath",
        str(wrapper_jar),
        "org.gradle.wrapper.GradleWrapperMain",
    ]
