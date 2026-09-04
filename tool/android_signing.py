#!/usr/bin/env python3
"""Prepare and verify stable Android signatures without logging private values.

Provisioning is explicit, local, and refuses to replace an existing key.
CI preparation reads Actions secrets from the environment; artifacts contain
only the signed APK and public integrity metadata.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION_BASE = 100_000_000
ANDROID_MAX_VERSION = 2_100_000_000
SECRET_NAMES = (
    "ANDROID_RELEASE_KEYSTORE_BASE64",
    "ANDROID_RELEASE_STORE_PASSWORD",
    "ANDROID_RELEASE_KEY_ALIAS",
    "ANDROID_RELEASE_KEY_PASSWORD",
    "ANDROID_RELEASE_CERT_SHA256",
)


class SigningError(Exception):
    """An intentionally redacted, actionable failure."""


def run(args, *, input_bytes=None, env=None):
    result = subprocess.run(args, input=input_bytes, env=env, capture_output=True)
    if result.returncode:
        # Tool output can contain key aliases, passwords, or untrusted inputs.
        raise SigningError(f"{Path(args[0]).name} failed (exit {result.returncode}); private output suppressed.")
    return result.stdout


def private_write(path, data):
    """Exclusive creation also rejects pre-existing symlinks."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def normalized_fingerprint(value):
    fingerprint = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[a-f0-9]{64}", fingerprint):
        raise SigningError("Expected one SHA-256 signing-certificate fingerprint.")
    return fingerprint


def version_code(run_number):
    if not re.fullmatch(r"[1-9][0-9]*", str(run_number)):
        raise SigningError("GITHUB_RUN_NUMBER must be a positive integer.")
    code = VERSION_BASE + int(run_number)
    if code > ANDROID_MAX_VERSION:
        raise SigningError("Android versionCode range exhausted; review the version policy.")
    return code


def properties_value(value):
    # java.util.Properties.load(InputStream) uses ISO-8859-1 and backslash
    # escapes. Escape UTF-16 units so paths/passwords round-trip exactly.
    out = []
    for index in range(0, len(encoded := value.encode("utf-16-be")), 2):
        unit = int.from_bytes(encoded[index:index + 2], "big")
        char = chr(unit)
        if char in "\\:=#! ":
            out.append("\\" + char)
        elif unit < 0x20 or unit > 0x7E:
            out.append(f"\\u{unit:04x}")
        else:
            out.append(char)
    return "".join(out)


def keytool():
    executable = shutil.which("keytool")
    if executable is None:
        raise SigningError("Install Java 17 and put keytool on PATH.")
    return executable


def certificate_fingerprint(keystore, alias, password):
    env = dict(os.environ, LARENOR_KEYSTORE_PASSWORD=password)
    certificate = run([
        keytool(), "-exportcert", "-keystore", str(keystore), "-alias", alias,
        "-storepass:env", "LARENOR_KEYSTORE_PASSWORD",
    ], env=env)
    return hashlib.sha256(certificate).hexdigest()


def secret_status(env):
    present = [name for name in SECRET_NAMES if env.get(name)]
    if not present:
        return False
    if len(present) != len(SECRET_NAMES):
        missing = sorted(set(SECRET_NAMES) - set(present))
        raise SigningError("Incomplete signing configuration; missing secret names: " + ", ".join(missing))
    return True


def prepare_ci(root, temporary, env):
    if not secret_status(env):
        return False
    expected = normalized_fingerprint(env[SECRET_NAMES[4]])
    try:
        key_bytes = base64.b64decode(env[SECRET_NAMES[0]], validate=True)
    except ValueError as error:
        raise SigningError("Signing keystore is not valid base64.") from error
    if not key_bytes or len(key_bytes) > 36_000:
        raise SigningError("Signing keystore must fit GitHub's 48 KB base64 secret limit.")
    properties = root / "android/key.properties"
    if properties.exists() or properties.is_symlink():
        raise SigningError("Refusing to overwrite existing android/key.properties.")
    directory = temporary / "larenor-signing"
    directory.mkdir(mode=0o700)
    keystore = directory / "release.p12"
    private_write(keystore, key_bytes)
    fingerprint = certificate_fingerprint(keystore, env[SECRET_NAMES[2]], env[SECRET_NAMES[1]])
    if fingerprint != expected:
        raise SigningError("Keystore certificate differs from the pinned release certificate.")
    values = {
        "storeFile": str(keystore.resolve()),
        "storePassword": env[SECRET_NAMES[1]],
        "keyAlias": env[SECRET_NAMES[2]],
        "keyPassword": env[SECRET_NAMES[3]],
    }
    private_write(properties, "".join(
        f"{key}={properties_value(value)}\n" for key, value in values.items()
    ).encode("ascii"))
    return True


def provision(directory):
    directory = directory.expanduser().resolve()
    if directory == ROOT or ROOT in directory.parents:
        raise SigningError("Signing keys must be created outside the repository.")
    # Never overwrite, reuse a debug key, or silently rotate an old identity.
    if directory.exists():
        raise SigningError("Signing directory already exists; reuse/recover the existing key instead.")
    directory.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.mkdir(mode=0o700)
    password = secrets.token_urlsafe(48)
    alias = "larenor-release"
    private_write(directory / "password.txt", password.encode("ascii"))
    keystore = directory / "release.p12"
    env = dict(os.environ, LARENOR_KEYSTORE_PASSWORD=password)
    run([
        keytool(), "-genkeypair", "-noprompt", "-keystore", str(keystore),
        "-storetype", "PKCS12", "-alias", alias, "-keyalg", "RSA", "-keysize", "3072",
        "-validity", "10000", "-dname", "CN=Larenor Android Release,O=Larenor,C=TR",
        "-storepass:env", "LARENOR_KEYSTORE_PASSWORD",
        "-keypass:env", "LARENOR_KEYSTORE_PASSWORD",
    ], env=env)
    keystore.chmod(0o600)
    metadata = {"alias": alias, "certificateSha256": certificate_fingerprint(keystore, alias, password)}
    private_write(directory / "identity.json", (json.dumps(metadata, indent=2) + "\n").encode())
    print("Created one private release identity outside the repository. Private values were not printed.")


def upload(directory, repository):
    directory = directory.expanduser().resolve()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise SigningError("Use an explicit owner/repository for GitHub secret provisioning.")
    paths = [directory, directory / "release.p12", directory / "password.txt", directory / "identity.json"]
    for path in paths:
        if path.is_symlink() or stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise SigningError("Signing directory/files must be private (0700/0600) and not symlinks.")
    metadata = json.loads(paths[3].read_text())
    password = paths[2].read_text()
    expected = normalized_fingerprint(metadata["certificateSha256"])
    if certificate_fingerprint(paths[1], metadata["alias"], password) != expected:
        raise SigningError("Local signing identity verification failed; nothing was uploaded.")
    existing = json.loads(run(["gh", "secret", "list", "--repo", repository, "--json", "name"]))
    if set(SECRET_NAMES) & {entry["name"] for entry in existing}:
        raise SigningError("Release secrets already exist; refusing to replace a signing identity.")
    values = [base64.b64encode(paths[1].read_bytes()), password.encode(),
              metadata["alias"].encode(), password.encode(), expected.encode()]
    for name, value in zip(SECRET_NAMES, values):
        if len(value) > 48_000:
            raise SigningError("A signing secret exceeds GitHub's size limit.")
        run(["gh", "secret", "set", name, "--repo", repository], input_bytes=value)
    print("Uploaded the five signing secrets. Keystore and passwords were not printed.")


def build_tool(name):
    android_home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not android_home:
        raise SigningError("ANDROID_HOME is required to verify the release APK.")
    tools = list((Path(android_home) / "build-tools").glob(f"*/{name}"))
    if not tools:
        raise SigningError(f"Android build tool {name} was not found.")
    return str(max(tools, key=lambda path: tuple(int(x) for x in re.findall(r"\d+", path.parent.name))))


def validate_apk_output(signature_output, badging_output, expected, expected_code):
    certificates = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9:]+)$",
                              signature_output, re.MULTILINE)
    if len(certificates) != 1 or normalized_fingerprint(certificates[0]) != normalized_fingerprint(expected):
        raise SigningError("Release APK is not signed only by the pinned release certificate.")
    if re.search(r"^Signer #\d+ certificate DN:.*CN=Android Debug(?:,|$)", signature_output, re.MULTILINE | re.IGNORECASE):
        raise SigningError("Android debug signing certificates are forbidden for release artifacts.")
    package = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']*)'", badging_output, re.MULTILINE)
    if not package or package[1] != "com.ersingundem.larenor" or int(package[2]) != expected_code:
        raise SigningError("Release APK package/version does not match this workflow run.")
    if re.search(r"^application-debuggable", badging_output, re.MULTILINE):
        raise SigningError("Release APK must not be debuggable.")
    return package[3]


def verify_apk(apk, expected, expected_code, output):
    signature = run([build_tool("apksigner"), "verify", "--verbose", "--print-certs", str(apk)]).decode()
    badging = run([build_tool("aapt"), "dump", "badging", str(apk)]).decode()
    version_name = validate_apk_output(signature, badging, expected, expected_code)
    with apk.open("rb") as stream:
        apk_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    metadata = {
        "applicationId": "com.ersingundem.larenor",
        "versionName": version_name,
        "versionCode": expected_code,
        "certificateSha256": normalized_fingerprint(expected),
        "apkSha256": apk_hash,
        "commit": os.environ.get("GITHUB_SHA"),
        "workflowRun": os.environ.get("GITHUB_RUN_ID"),
    }
    output.write_text(json.dumps(metadata, indent=2) + "\n")
    print("Release APK signature, certificate, application ID, versionCode, and non-debuggable flag verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("provision", "upload"):
        command = commands.add_parser(name)
        command.add_argument("--directory", type=Path, required=True)
        if name == "upload":
            command.add_argument("--repo", required=True)
    commands.add_parser("prepare-ci")
    commands.add_parser("check-ci")
    commands.add_parser("version-code")
    verify = commands.add_parser("verify-apk")
    verify.add_argument("--apk", type=Path, required=True)
    verify.add_argument("--metadata", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "provision":
        provision(args.directory)
    elif args.command == "upload":
        upload(args.directory, args.repo)
    elif args.command == "version-code":
        print(version_code(os.environ.get("GITHUB_RUN_NUMBER", "")))
    elif args.command in {"prepare-ci", "check-ci"}:
        configured = (secret_status(os.environ) if args.command == "check-ci"
                      else prepare_ci(ROOT, Path(os.environ["RUNNER_TEMP"]), os.environ))
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"available={str(configured).lower()}\n")
        if not configured:
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                stream.write("Signed release skipped: release signing secrets are not provisioned. Debug CI remains available.\n")
            print("Signed release skipped: release signing secrets are not provisioned.")
    elif args.command == "verify-apk":
        verify_apk(args.apk, os.environ[SECRET_NAMES[4]],
                   version_code(os.environ.get("GITHUB_RUN_NUMBER", "")), args.metadata)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (SigningError, OSError, ValueError, KeyError) as error:
        # Only our own messages are known not to contain secret values.
        message = str(error) if isinstance(error, SigningError) else type(error).__name__
        print(f"Signing operation stopped: {message}", file=sys.stderr)
        sys.exit(1)
