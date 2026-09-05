"""Offline image/publication policy checks; never build or contact Docker/GHCR.

The workflow uses JSON, which is valid YAML, so its permission and dependency
graph can be checked with the standard library on both macOS and CI runners.
These checks do not replace the native image smoke tests in that workflow.
"""

import ast
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = (ROOT / "server/Dockerfile").read_text()
WORKFLOW = json.loads((ROOT / ".github/workflows/server-build.yml").read_text())
STEPS = WORKFLOW["jobs"]["build-test"]["steps"]


def step_named(name, steps=STEPS):
    return next(step for step in steps if step.get("name") == name)


def python_blocks(script):
    return re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY(?:\n|$)", script, re.DOTALL)


class SmokeRestartTest(unittest.TestCase):
    def test_media_http_journey_is_inside_both_architecture_smokes_after_private_restart(self):
        script = python_blocks(step_named("Smoke-test the exact image before publication")["run"])[0]
        nodes = ast.parse(script).body
        calls = [node for node in nodes if isinstance(node, ast.Expr)
                 and isinstance(node.value, ast.Call)
                 and isinstance(node.value.func, ast.Name)
                 and node.value.func.id == "verify_media_preparation"]
        self.assertEqual(len(calls), 1, "Actual media HTTP smoke must gate image publication")
        call = calls[0]
        private_assert = next(node for node in nodes if isinstance(node, ast.Assert)
                              and "private_state" in ast.unparse(node))
        self.assertGreater(call.lineno, private_assert.lineno)
        self.assertEqual(ast.unparse(call.value),
                         "verify_media_preparation(name, healthy, 'linux/' + os.environ['ARCH'])")

    def health_function(self, ports, opener):
        script = python_blocks(step_named("Smoke-test the exact image before publication")["run"])[0]
        node = next(node for node in ast.parse(script).body if isinstance(node, ast.FunctionDef) and node.name == "healthy")
        docker = SimpleNamespace(check_output=Mock(side_effect=ports), run=Mock(),
                                 CalledProcessError=subprocess.CalledProcessError,
                                 TimeoutExpired=subprocess.TimeoutExpired)
        clock = SimpleNamespace(sleep=Mock())
        namespace = {"subprocess": docker, "name": "synthetic-smoke", "json": json, "re": re,
                     "time": clock, "urlopen": opener, "URLError": URLError,
                     "base": "http://127.0.0.1:41001/api/v1"}
        exec(compile(ast.Module(body=[node], type_ignores=[]), "smoke_health", "exec"), namespace)
        return namespace["healthy"], docker, clock

    def test_restart_discovers_new_ephemeral_port(self):
        urls = []
        def opener(url, timeout):
            self.assertEqual(timeout, 2)
            urls.append(url)
            return io.BytesIO(b'{"service":"larenor-server","apiVersion":1}')
        healthy, docker, clock = self.health_function(["127.0.0.1:41001\n", "127.0.0.1:42002\n"], opener)
        self.assertEqual(healthy(), "http://127.0.0.1:41001/api/v1")
        self.assertEqual(healthy(), "http://127.0.0.1:42002/api/v1")
        self.assertEqual(urls, ["http://127.0.0.1:41001/api/v1/health", "http://127.0.0.1:42002/api/v1/health"])
        self.assertEqual(docker.check_output.call_count, 2)
        self.assertFalse(clock.sleep.called)

    def test_genuine_health_failure_still_blocks_and_emits_bounded_diagnostics(self):
        opener = Mock(side_effect=URLError("synthetic connection refused"))
        healthy, docker, clock = self.health_function(["127.0.0.1:41001\n"] * 60, opener)
        with self.assertRaises(AssertionError):
            healthy()
        self.assertEqual(opener.call_count, 60)
        self.assertEqual(clock.sleep.call_count, 60)
        commands = [call.args[0] for call in docker.run.call_args_list]
        self.assertIn(["docker", "logs", "--tail", "80", "synthetic-smoke"], commands)
        self.assertTrue(any(command[:3] == ["docker", "inspect", "--format"] for command in commands))
        self.assertTrue(all(call.kwargs.get("timeout") == 10 for call in docker.run.call_args_list))

    def test_wrong_service_health_payload_fails_immediately(self):
        healthy, _, clock = self.health_function(["127.0.0.1:41001\n"], lambda *_args, **_kwargs: io.BytesIO(b'{"service":"other","apiVersion":1}'))
        with self.assertRaises(AssertionError):
            healthy()
        self.assertFalse(clock.sleep.called)

    def test_health_discovery_rejects_non_loopback_or_multiple_bindings(self):
        for binding in ("0.0.0.0:41001\n", "127.0.0.1:0\n", "127.0.0.1:70000\n", "127.0.0.1:41001\n[::]:41001\n"):
            with self.subTest(binding=binding):
                opener = Mock()
                healthy, _, _ = self.health_function([binding], opener)
                with self.assertRaises(AssertionError):
                    healthy()
                self.assertFalse(opener.called)


class ContainerBoundaryTest(unittest.TestCase):
    def test_all_base_images_are_immutable_and_versions_are_explicit(self):
        images = re.findall(r"^FROM (\S+)", DOCKERFILE, re.MULTILINE)
        self.assertEqual(len(images), 4)
        for image in images:
            self.assertRegex(image, r"^[\w./-]+:[\w.-]+@sha256:[0-9a-f]{64}$")
        self.assertEqual(images[2], images[3], "Build and runtime Python ABI must match")
        self.assertIn("python:3.12.14-slim-bookworm@", images[3])
        self.assertIn("ghcr.io/astral-sh/uv:0.12.10@", images[0])
        self.assertIn("eclipse-temurin:17-jdk-jammy@", images[1])

    def test_packaged_verifier_matches_the_runtime_trust_pin(self):
        tree = ast.parse((ROOT / "server/larenor_server/releases/verifier.py").read_text())
        constants = {
            node.targets[0].id: ast.literal_eval(node.value)
            for node in tree.body
            if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in {"APKSIG_SHA256", "APKSIG_VERSION"}
        }
        self.assertIn("ADD --checksum=sha256:" + constants["APKSIG_SHA256"], DOCKERFILE)
        version = constants["APKSIG_VERSION"]
        self.assertIn(f"https://dl.google.com/dl/android/maven2/com/android/tools/build/apksig/{version}/apksig-{version}.jar", DOCKERFILE)
        self.assertIn("javac --release 17", DOCKERFILE)
        self.assertIn("jdk.crypto.ec", DOCKERFILE)
        self.assertIn('exec /opt/larenor/java/bin/java "$@"', DOCKERFILE)

    def test_remote_verifier_download_is_readable_without_runtime_write_access(self):
        # Remote ADD defaults to root:root 0600, even if root can compile with
        # the artifact. The copied JAR must remain readable by UID 10001.
        instruction = next(line for line in DOCKERFILE.splitlines()
                           if line.startswith("ADD ") and "apksig.jar" in line)
        flags = shlex.split(instruction)
        self.assertIn("--chmod=0644", flags)
        mode = int(next(flag.split("=", 1)[1] for flag in flags if flag.startswith("--chmod=")), 8)
        self.assertTrue(mode & 0o004)
        self.assertFalse(mode & 0o022)

    def test_final_image_checks_verifier_inputs_as_the_runtime_user(self):
        runtime_user_steps = DOCKERFILE.split("USER 10001:10001\n", 1)[1]
        check = next(line[4:] for line in runtime_user_steps.splitlines() if line.startswith("RUN "))
        command = shlex.split(check)
        self.assertEqual(command[:2], ["python", "-c"])
        compile(command[2], "nonroot_verifier_inputs", "exec")
        self.assertIn("os.geteuid() == 10001", command[2])
        self.assertIn("hashlib.sha256(jar.read_bytes()).hexdigest() == APKSIG_SHA256", command[2])
        self.assertIn("VerifyApk.class", command[2])
        self.assertIn(".read_bytes()", command[2])

    def test_runtime_is_nonroot_and_separates_private_persistent_state(self):
        runtime = DOCKERFILE.rsplit(" AS runtime\n", 1)[1]
        self.assertIn("USER 10001:10001", runtime)
        self.assertIn("install -d -m 0700 -o 10001 -g 10001 /data /secrets", runtime)
        for assignment in (
            "LARENOR_DATA_DIR=/data", "LARENOR_KEY_FILE=/secrets/vault.key",
            "LARENOR_PUBLISHER_TOKEN_FILE=/secrets/publisher.token",
            "LARENOR_JAVA=/usr/bin/java", "PYTHONDONTWRITEBYTECODE=1",
        ):
            self.assertIn(assignment, runtime)
        self.assertIn('ENTRYPOINT ["/opt/larenor/.venv/bin/python", "-m", "larenor_server.cli"]', runtime)
        self.assertIn("/api/v1/health", runtime)
        self.assertNotRegex(runtime, r"(?i)(pip install|uv sync|apt-get|curl|wget)")
        self.assertNotIn("--from=uv", runtime)
        self.assertIn("uv sync --locked --no-dev --no-editable", DOCKERFILE)

    def test_exact_source_and_license_material_are_in_the_image(self):
        self.assertIn("ARG LARENOR_SOURCE_REVISION", DOCKERFILE)
        self.assertIn('re.fullmatch(r"[0-9a-f]{40}"', DOCKERFILE)
        self.assertIn("LARENOR_SOURCE_URL=${LARENOR_REPOSITORY_URL}/tree/${LARENOR_SOURCE_REVISION}", DOCKERFILE)
        self.assertIn("LARENOR_LICENSE_URL=${LARENOR_REPOSITORY_URL}/blob/${LARENOR_SOURCE_REVISION}/LICENSE", DOCKERFILE)
        self.assertIn("COPY LICENSE NOTICE THIRD_PARTY_NOTICES.md /usr/share/doc/larenor-server/", DOCKERFILE)
        self.assertIn("/usr/share/doc/larenor-server/APKSIG-LICENSE", DOCKERFILE)
        for label in ("source", "revision", "licenses"):
            self.assertIn("org.opencontainers.image." + label, DOCKERFILE)

    def test_dockerfile_build_commands_parse_without_running(self):
        for instruction in DOCKERFILE.replace("\\\n", " ").splitlines():
            if instruction.startswith("RUN "):
                result = subprocess.run(["sh", "-n"], input=instruction[4:], text=True,
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_root_build_context_has_a_narrow_dockerfile_specific_allowlist(self):
        ignore = ROOT / "server/Dockerfile.dockerignore"
        rules = [line for line in ignore.read_text().splitlines() if line and not line.startswith("#")]
        self.assertEqual(rules[0], "**")
        allowed = {rule[1:] for rule in rules if rule.startswith("!")}
        self.assertEqual(allowed, {
            "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "server/", "server/Dockerfile",
            "server/pyproject.toml", "server/uv.lock", "server/larenor_server/", "server/larenor_server/**",
            "android/", "android/app/", "android/app/src/", "android/app/src/test/",
            "android/app/src/test/resources/", "android/app/src/test/resources/updater/",
            "android/app/src/test/resources/updater/LICENSE.apksig",
        })
        for protected in ("**/__pycache__/", "**/*.key", "**/*.token", "**/*.sqlite3*", "**/.env", "**/.env.*"):
            self.assertIn(protected, rules)
        build = step_named("Build native image without publishing")["with"]
        self.assertEqual((build["context"], build["file"]), (".", "server/Dockerfile"))


class PublicationGraphTest(unittest.TestCase):
    def test_publication_cannot_be_entered_from_pull_requests_or_forks(self):
        self.assertEqual(set(WORKFLOW["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(WORKFLOW["on"]["push"]["branches"], ["main"])
        self.assertFalse(WORKFLOW["on"]["workflow_dispatch"]["inputs"]["publish"]["default"])
        self.assertEqual(WORKFLOW["permissions"], {"contents": "read"})
        for job in WORKFLOW["jobs"].values():
            guard = job["if"]
            self.assertIn("github.repository == 'ersingundem/larenor'", guard)
            self.assertIn("github.ref == 'refs/heads/main'", guard)
            self.assertIn("github.event_name == 'push'", guard)
            self.assertIn("github.event_name == 'workflow_dispatch'", guard)
            self.assertNotIn("pull_request", guard)
            self.assertLessEqual(set(job.get("permissions", {})), {"contents", "packages"})

    def test_reusable_tests_and_both_architectures_gate_the_final_manifest(self):
        jobs = WORKFLOW["jobs"]
        self.assertEqual(jobs["server-test"]["uses"], "./.github/workflows/server-test.yml")
        self.assertEqual(jobs["build-test"]["needs"], ["server-test"])
        self.assertEqual(set(jobs["publish-manifest"]["needs"]), {"server-test", "build-test"})
        self.assertEqual(jobs["build-test"]["strategy"]["matrix"]["include"], [
            {"arch": "amd64", "runner": "ubuntu-24.04"},
            {"arch": "arm64", "runner": "ubuntu-24.04-arm"},
        ])
        self.assertEqual(WORKFLOW["concurrency"], {"group": "server-image-main", "cancel-in-progress": True})

    def test_only_the_exact_smoked_image_can_be_pushed(self):
        build = step_named("Build native image without publishing")["with"]
        self.assertIs(build["load"], True)
        self.assertIs(build["push"], False)
        names = [step.get("name") for step in STEPS]
        smoke = names.index("Smoke-test the exact image before publication")
        push = names.index("Publish a new immutable architecture tag")
        self.assertLess(smoke, push)
        self.assertFalse(any("build-push-action" in step.get("uses", "") for step in STEPS[smoke + 1:]))
        push_step = STEPS[push]
        self.assertIn("steps.current.outputs.current == 'true'", push_step["if"])
        self.assertIn("steps.existing.outputs.digest == ''", push_step["if"])
        self.assertIn('docker tag "$LOCAL_IMAGE" "$tag"', push_step["run"])
        self.assertIn('sha-$GITHUB_SHA-$ARCH', push_step["run"])
        reuse = step_named("Reuse an existing image by immutable digest")
        self.assertIn('docker pull "$IMAGE@$EXISTING_DIGEST"', reuse["run"])
        final = WORKFLOW["jobs"]["publish-manifest"]["steps"][-1]["run"]
        self.assertLess(final.rindex('gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main"'), final.index('--tag "$IMAGE:stable"'))
        self.assertIn("Existing commit index does not match tested images", final)

    def test_actions_are_official_and_pinned_and_image_archives_are_not_uploaded(self):
        for job in WORKFLOW["jobs"].values():
            for step in job.get("steps", []):
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^(actions|docker)/[a-z-]+@[0-9a-f]{40}$")
                    self.assertNotIn("upload-artifact", step["uses"])
                if step.get("uses", "").startswith("actions/checkout@"):
                    self.assertIs(step["with"]["persist-credentials"], False)
        self.assertEqual(WORKFLOW["env"]["DOCKER_BUILD_RECORD_UPLOAD"], "false")

    def test_workflow_shell_and_embedded_python_parse_without_execution(self):
        for job in WORKFLOW["jobs"].values():
            for step in job.get("steps", []):
                if "run" not in step:
                    continue
                result = subprocess.run(["bash", "-n"], input=step["run"], text=True,
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 0, step.get("name") + ": " + result.stderr)
                for code in python_blocks(step["run"]):
                    compile(code, step["name"], "exec")
                    for node in ast.parse(code).body:
                        if (isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                                and node.targets[0].id in {"private_check", "verifier_check"}):
                            compile(ast.literal_eval(node.value), node.targets[0].id, "exec")
        smoke = step_named("Smoke-test the exact image before publication")["run"]
        for required in ("--read-only", "--cap-drop ALL", "no-new-privileges", "--initialize-only",
                         "verifier.verify(fixture)", "private_state() == before", "docker','restart'"):
            self.assertIn(required, smoke)


class Response(io.BytesIO):
    def __init__(self, body=b"", status=200, headers=None):
        super().__init__(body)
        self.status = status
        self.headers = headers or {}


class RegistryFailureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        code = python_blocks(step_named("Prepare immutable registry lookup")["run"])[0]
        namespace = {"__name__": "offline_registry_policy"}
        exec(compile(code, "registry_lookup_from_workflow", "exec"), namespace)
        cls.lookup = staticmethod(namespace["registry_digest"])

    def lookup_with(self, head):
        calls = []

        def opener(request, timeout):
            calls.append(request)
            self.assertEqual(timeout, 30)
            if len(calls) == 1:
                self.assertTrue(request.full_url.startswith("https://ghcr.io/token?"))
                return Response(b'{"token":"synthetic-token"}')
            self.assertEqual(request.get_method(), "HEAD")
            if isinstance(head, Exception):
                raise head
            return head

        return self.lookup("ghcr.io/ersingundem/larenor-server", "sha-" + "a" * 40,
                           "synthetic-actor", "synthetic-credential", opener)

    def test_only_a_real_not_found_response_allows_a_new_immutable_tag(self):
        self.assertEqual(self.lookup_with(HTTPError("https://ghcr.io/", 404, "Not found", {}, None)), "")
        digest = "sha256:" + "a" * 64
        self.assertEqual(self.lookup_with(Response(headers={"Docker-Content-Digest": digest})), digest)

    def test_registry_failures_cannot_be_mistaken_for_unused_tags(self):
        for code in (401, 403, 429, 500, 503):
            with self.subTest(status=code), self.assertRaises(RuntimeError):
                self.lookup_with(HTTPError("https://ghcr.io/", code, "Failure", {}, None))
        with self.assertRaises(URLError):
            self.lookup_with(URLError("synthetic network failure"))
        for response in (Response(), Response(status=201), Response(headers={"Docker-Content-Digest": "bad"})):
            with self.assertRaises(RuntimeError):
                self.lookup_with(response)


if __name__ == "__main__":
    unittest.main()
