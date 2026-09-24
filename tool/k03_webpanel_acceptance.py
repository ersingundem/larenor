#!/usr/bin/env python3
"""Validate the immutable K03 WebPanel software-acceptance evidence."""

import argparse
import json
from pathlib import Path
import re
import stat
import sys


ACCEPTED_SOURCE_COMMIT = "ac8e1af6c5564fbc41eb5ea50d15241d01da2a87"
ACCEPTED_MERGE_COMMIT = "7211a6ffca6008bcb30d9ec4d6849e222fc81092"
ANDROID_RUN = "https://github.com/ersingundem/larenor/actions/runs/35941771379"
SECURITY_RUN = "https://github.com/ersingundem/larenor/actions/runs/35941771192"
SHA = re.compile(r"[0-9a-f]{40}\Z")
REFERENCE = re.compile(
    r"(?:android|docs|integration_test|test|tool)/[A-Za-z0-9_./-]+\Z"
)
MAX_MANIFEST_BYTES = 64 * 1024
MAX_REFERENCE_BYTES = 2 * 1024 * 1024

REQUIRED_REFERENCES = {
    "production": frozenset(
        {
            "android/app/src/main/kotlin/com/ersingundem/larenor/webpanel/WebPanelOwnedTransport.kt",
            "android/app/src/main/kotlin/com/ersingundem/larenor/webpanel/WebPanelRendererBridge.kt",
        }
    ),
    "test": frozenset(
        {
            "android/app/src/test/kotlin/com/ersingundem/larenor/webpanel/WebPanelOwnedTransportTest.kt",
            "android/app/src/test/kotlin/com/ersingundem/larenor/webpanel/WebPanelRendererBridgeTest.kt",
            "integration_test/web_panel_owned_transport_test.dart",
            "integration_test/web_panel_dynamic_context_matrix_test.dart",
            "integration_test/web_panel_dynamic_egress_test.dart",
        }
    ),
    "review": frozenset(
        {"docs/testing/k03-webpanel-advanced-browser-operations.tdd.md"}
    ),
}

REQUIRED_MARKERS = {
    "android/app/src/main/kotlin/com/ersingundem/larenor/webpanel/WebPanelOwnedTransport.kt": frozenset(
        {
            "internal class WebPanelOwnedHttpTransport(",
            "private fun fetchWithPermit(",
            "if (!firewall.allows(Uri.parse(next.toString())))",
            ".cookieJar(CookieJar.NO_COOKIES)",
            ".proxy(Proxy.NO_PROXY)",
            ".followRedirects(false)",
            "internal class WebPanelDynamicEgressPolicy(",
            "Object.defineProperty(globalThis, 'WebSocket'",
            "Object.defineProperty(globalThis, 'Worker'",
            "Object.defineProperty(globalThis, 'SharedWorker'",
        }
    ),
    "android/app/src/main/kotlin/com/ersingundem/larenor/webpanel/WebPanelRendererBridge.kt": frozenset(
        {
            "internal class ServiceWorkerRequestFirewall(",
            "settings.setBlockNetworkLoads(true)",
            "override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest)",
            "request.isForMainFrame",
            "ownedTransport?.fetch(request.url, request.method)",
        }
    ),
    "android/app/src/test/kotlin/com/ersingundem/larenor/webpanel/WebPanelOwnedTransportTest.kt": frozenset(
        {
            "fun ownedTransportFollowsOnlyExactOriginRedirectsWithoutWebViewCredentials()",
            "fun exactDeclaredLengthReadReturnsSharedPermitWithoutEofOrCallerClose()",
            "fun documentStartGuardRequiresOfficialFeatureAndSealsDynamicEgress()",
        }
    ),
    "android/app/src/test/kotlin/com/ersingundem/larenor/webpanel/WebPanelRendererBridgeTest.kt": frozenset(
        {
            "fun exactOriginFirewallOwnsSubresourcesWithoutReadingHeadersOrBody()",
            "fun serviceWorkerBoundaryRequiresEveryClosedFeatureAndFailsOnMutationError()",
            "fun credentialAndTlsChallengesFailClosedBeforeThePluginDelegate()",
        }
    ),
    "integration_test/web_panel_owned_transport_test.dart": frozenset(
        {
            "API 35 owned transport contains redirects and oversized responses",
            "redirect:loaded,foreign:blocked,oversize:blocked",
            "expect(foreignRequests, 0)",
        }
    ),
    "integration_test/web_panel_dynamic_context_matrix_test.dart": frozenset(
        {
            "API 35 applies dynamic egress policy to every frame and reload",
            "SharedWorker:SecurityError",
            "final secondLoad = 'load=2;$result'",
        }
    ),
    "integration_test/web_panel_dynamic_egress_test.dart": frozenset(
        {
            "API 35 sandboxed srcdoc cannot create dynamic network egress",
            "WebSocket:SecurityError,EventSource:SecurityError",
            "WebTransport:SecurityError,Worker:SecurityError",
        }
    ),
}

ANDROID_REQUIRED_JOBS = frozenset(
    {
        "build-debug-apk",
        "analyze-test / static-analysis",
        "analyze-test / flutter-test (0)",
        "analyze-test / flutter-test (1)",
        "analyze-test / flutter-test (2)",
        "analyze-test / flutter-test (3)",
        "server-test / server-test-shard-0",
        "server-test / server-test-shard-1",
        "server-test / server-test-shard-2",
        "server-test / server-test-shard-3",
        "server-test / server-test",
        "end-to-end / emulator-journeys",
    }
)
SECURITY_REQUIRED_JOBS = frozenset(
    {"dependency-scan", "platform-policy", "secret-scan"}
)


class AcceptanceError(ValueError):
    """Static failure codes safe for local and CI output."""


def _require(condition, code):
    if not condition:
        raise AcceptanceError(code)


def _exact_fields(value, fields):
    _require(type(value) is dict and set(value) == set(fields), "invalid_schema")


def validate_reference_content(path, content):
    _require(isinstance(content, str), "invalid_reference")
    for marker in REQUIRED_MARKERS.get(path, ()):
        _require(marker in content, "missing_guard")


def _reference(path, root):
    _require(
        isinstance(path, str)
        and REFERENCE.fullmatch(path)
        and ".." not in path.split("/")
        and "//" not in path
        and not path.endswith("/"),
        "invalid_reference",
    )
    target = root / path
    try:
        value = target.lstat()
    except OSError as error:
        raise AcceptanceError("missing_reference") from error
    _require(stat.S_ISREG(value.st_mode) and not target.is_symlink(), "invalid_reference")
    _require(0 < value.st_size <= MAX_REFERENCE_BYTES, "invalid_reference")
    try:
        content = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise AcceptanceError("invalid_reference") from error
    validate_reference_content(path, content)


def _ci(value, *, url, jobs):
    _exact_fields(value, ("url", "commit", "result", "requiredJobs"))
    _require(value["url"] == url, "invalid_ci")
    _require(value["commit"] == ACCEPTED_SOURCE_COMMIT, "stale_ci")
    _require(value["result"] == "passed", "invalid_ci")
    required_jobs = value["requiredJobs"]
    _require(
        type(required_jobs) is list
        and all(isinstance(item, str) and item for item in required_jobs)
        and len(required_jobs) == len(set(required_jobs))
        and frozenset(required_jobs) == jobs,
        "missing_ci_job",
    )


def validate_manifest(value, root):
    root = Path(root).resolve()
    _exact_fields(
        value,
        (
            "schemaVersion",
            "task",
            "sourceCommit",
            "mergeCommit",
            "references",
            "ci",
            "manualBoundary",
        ),
    )
    _require(value["schemaVersion"] == 1, "invalid_schema")
    _require(value["task"] == "K03.remaining", "invalid_task")
    _require(
        isinstance(value["sourceCommit"], str)
        and SHA.fullmatch(value["sourceCommit"])
        and value["sourceCommit"] == ACCEPTED_SOURCE_COMMIT,
        "stale_source",
    )
    _require(
        isinstance(value["mergeCommit"], str)
        and SHA.fullmatch(value["mergeCommit"])
        and value["mergeCommit"] == ACCEPTED_MERGE_COMMIT,
        "stale_merge",
    )
    references = value["references"]
    _exact_fields(references, REQUIRED_REFERENCES)
    for group, required in REQUIRED_REFERENCES.items():
        actual = references[group]
        _require(
            type(actual) is list
            and all(isinstance(path, str) for path in actual),
            "invalid_reference",
        )
        for path in actual:
            _reference(path, root)
        _require(
            len(actual) == len(set(actual)) and frozenset(actual) == required,
            "missing_reference",
        )
    ci = value["ci"]
    _exact_fields(ci, ("android", "security"))
    _ci(ci["android"], url=ANDROID_RUN, jobs=ANDROID_REQUIRED_JOBS)
    _ci(ci["security"], url=SECURITY_RUN, jobs=SECURITY_REQUIRED_JOBS)
    _require(
        value["manualBoundary"]
        == "Physical Android, DeX and OEM behavior remains a separate manual gate.",
        "invalid_manual_boundary",
    )
    return value


def load_manifest(path, root=None):
    path = Path(path)
    root = path.resolve().parents[2] if root is None else Path(root)
    try:
        file_stat = path.lstat()
        _require(
            stat.S_ISREG(file_stat.st_mode)
            and not path.is_symlink()
            and 0 < file_stat.st_size <= MAX_MANIFEST_BYTES,
            "invalid_manifest",
        )
        value = json.loads(path.read_text(encoding="utf-8"))
    except AcceptanceError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AcceptanceError("invalid_manifest") from error
    return validate_manifest(value, root)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "docs/testing/k03-webpanel-acceptance.json",
    )
    args = parser.parse_args(argv)
    try:
        value = load_manifest(args.manifest)
    except AcceptanceError as error:
        sys.stderr.write("K03 acceptance error: %s\n" % error)
        return 2
    sys.stdout.write(
        "K03 acceptance PASS %s %s\n"
        % (value["sourceCommit"], value["mergeCommit"])
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
