# Build from the repository root using server/Dockerfile.dockerignore.
# Image indexes were verified on 2026-09-05; see docs/server-container.md.
FROM ghcr.io/astral-sh/uv:0.12.10@sha256:2bb3ebca0a796a155094a27773d290c4b074572e6107f171d88d086682fd2500 AS uv

FROM eclipse-temurin:17-jdk-jammy@sha256:400014962ad7224461f945bb1cc3d7d5a1927ce15b8245b72d9cedcda554cd2a AS verifier
WORKDIR /build
ADD --checksum=sha256:562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201 https://dl.google.com/dl/android/maven2/com/android/tools/build/apksig/9.1.0/apksig-9.1.0.jar /opt/larenor/verifier/apksig.jar
COPY server/larenor_server/releases/java/VerifyApk.java ./VerifyApk.java
RUN javac --release 17 -cp /opt/larenor/verifier/apksig.jar \
      -d /opt/larenor/verifier/classes VerifyApk.java \
    && jlink --add-modules java.base,java.logging,java.xml,jdk.crypto.ec \
      --strip-debug --no-man-pages --no-header-files --compress=2 \
      --output /opt/larenor/java \
    && mkdir -p /opt/larenor/java-native /opt/larenor/java-native/legal \
    && for library in libstdc++.so.6 libgcc_s.so.1; do \
         location="$(ldconfig -p | awk -v name="$library" '$1 == name { print $NF; exit }')"; \
         test -n "$location" && cp -L "$location" "/opt/larenor/java-native/$library" || exit 1; \
       done \
    && cp -L /usr/share/doc/libstdc++6/copyright /opt/larenor/java-native/legal/libstdc++6-copyright \
    && cp -L /usr/share/doc/libgcc-s1/copyright /opt/larenor/java-native/legal/libgcc-s1-copyright

FROM python:3.12.14-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254 AS dependencies
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /opt/larenor
ENV UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy UV_COMPILE_BYTECODE=1
COPY server/pyproject.toml server/uv.lock ./
RUN uv sync --locked --no-dev --no-install-project --python /usr/local/bin/python3
COPY server/larenor_server ./larenor_server
RUN uv sync --locked --no-dev --no-editable --python /usr/local/bin/python3 \
    && uv pip check --python /opt/larenor/.venv/bin/python

FROM python:3.12.14-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254 AS runtime
ARG LARENOR_REPOSITORY_URL=https://github.com/ersingundem/larenor
ARG LARENOR_SOURCE_REVISION
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/larenor/.venv/bin:/usr/local/bin:/usr/bin:/bin \
    HOME=/tmp \
    LARENOR_DATA_DIR=/data \
    LARENOR_KEY_FILE=/secrets/vault.key \
    LARENOR_PUBLISHER_TOKEN_FILE=/secrets/publisher.token \
    LARENOR_JAVA=/usr/bin/java \
    LARENOR_APKSIG_JAR=/opt/larenor/verifier/apksig.jar \
    LARENOR_APKSIG_CLASSES=/opt/larenor/verifier/classes \
    LARENOR_SOURCE_REVISION=${LARENOR_SOURCE_REVISION} \
    LARENOR_SOURCE_URL=${LARENOR_REPOSITORY_URL}/tree/${LARENOR_SOURCE_REVISION} \
    LARENOR_LICENSE_URL=${LARENOR_REPOSITORY_URL}/blob/${LARENOR_SOURCE_REVISION}/LICENSE
LABEL org.opencontainers.image.title="Larenor Server" \
      org.opencontainers.image.description="Private accounts, encrypted configuration and verified Client releases" \
      org.opencontainers.image.source=${LARENOR_REPOSITORY_URL} \
      org.opencontainers.image.revision=${LARENOR_SOURCE_REVISION} \
      org.opencontainers.image.licenses="AGPL-3.0-only"
WORKDIR /opt/larenor
COPY --from=dependencies /opt/larenor/.venv ./.venv
COPY --from=verifier /opt/larenor/verifier ./verifier
COPY --from=verifier /opt/larenor/java ./java
COPY --from=verifier /opt/larenor/java-native ./java-native
COPY LICENSE NOTICE THIRD_PARTY_NOTICES.md /usr/share/doc/larenor-server/
COPY android/app/src/test/resources/updater/LICENSE.apksig /usr/share/doc/larenor-server/APKSIG-LICENSE
# The verifier deliberately clears ambient environment variables. Keep Java's
# native support libraries private and set their path in this fixed launcher.
RUN python3 -c 'import os,re; assert re.fullmatch(r"[0-9a-f]{40}", os.environ["LARENOR_SOURCE_REVISION"]), "A full source commit is required"' \
    && /usr/sbin/groupadd --gid 10001 larenor \
    && /usr/sbin/useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin larenor \
    && install -d -m 0700 -o 10001 -g 10001 /data /secrets \
    && printf '%s\n' '#!/bin/sh' 'export LD_LIBRARY_PATH=/opt/larenor/java-native' 'exec /opt/larenor/java/bin/java "$@"' > /usr/bin/java \
    && chmod 0755 /usr/bin/java \
    && /usr/bin/java -version \
    && python3 -c 'from larenor_server.legal import SourceInformation; SourceInformation.from_environment()'
USER 10001:10001
EXPOSE 8098
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/opt/larenor/.venv/bin/python", "-c", "import json,urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8098/api/v1/health', timeout=3); assert r.status == 200 and json.load(r)['service'] == 'larenor-server'"]
ENTRYPOINT ["/opt/larenor/.venv/bin/python", "-m", "larenor_server.cli"]
CMD ["--host", "0.0.0.0", "--port", "8098"]
