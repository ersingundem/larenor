#!/usr/bin/env bash
# Sourced by both stages so native compilation and emulator tests reuse the
# same bounded Gradle daemon/cache. Developer preferences stay unchanged.
# https://docs.gradle.org/current/userguide/build_environment.html
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  e2e_gradle_home="${RUNNER_TEMP:?CI requires RUNNER_TEMP}/larenor-e2e-gradle"
  mkdir -p "$e2e_gradle_home"
  cat > "$e2e_gradle_home/gradle.properties" <<'PROPERTIES'
org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m -Dfile.encoding=UTF-8
org.gradle.workers.max=2
org.gradle.parallel=false
kotlin.compiler.execution.strategy=in-process
PROPERTIES
  export GRADLE_USER_HOME="$e2e_gradle_home"
fi
