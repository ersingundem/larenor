#!/usr/bin/env python3
"""Run the production Android VNC bridge against an owned TigerVNC Xvnc."""

from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

if __package__:
    from .android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from .native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )
else:
    from android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )


ROOT = Path(__file__).resolve().parents[1]
TEST_CLASS = "com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest"
TEST_NAME = "normalBridgeInteroperatesWithOwnedTigerVncAndRetiresWithoutReplay"
OUTPUT = ROOT / "build" / "f61-tigervnc-acceptance"
REPORT = (
    ROOT
    / "build/app/test-results/testDebugUnitTest"
    / "TEST-com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest.xml"
)


class AcceptanceFailure(RuntimeError):
    pass


def executable(*names: str) -> str:
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    raise AcceptanceFailure(f"missing required fixture executable: {', '.join(names)}")


def fixture_address(ip: str) -> str:
    value = ipaddress.ip_address(ip)
    if value.version != 4 or value.is_loopback or value.is_link_local or value.is_multicast:
        raise AcceptanceFailure("fixture address must be a non-loopback IPv4 address")
    return str(value)


def discover_address(ip_command: str) -> str:
    result = subprocess.run(
        [ip_command, "-j", "-4", "route", "get", "1.1.1.1"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    try:
        records = json.loads(result.stdout)
        addresses = sorted({
            fixture_address(record["prefsrc"])
            for record in records
            if "prefsrc" in record
        })
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise AcceptanceFailure("unable to read the isolated runner address") from error
    if len(addresses) != 1:
        raise AcceptanceFailure("the isolated runner must expose exactly one global IPv4 address")
    return addresses[0]


def reserve_port(address: str) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind((address, 0))
        return listener.getsockname()[1]


def available_display() -> int:
    for number in range(90, 100):
        if not Path(f"/tmp/.X11-unix/X{number}").exists():
            return number
    raise AcceptanceFailure("no isolated X display number is available")


def wait_for_display(display: str, xdpyinfo: str, process: subprocess.Popen[bytes]) -> None:
    for _ in range(100):
        if process.poll() is not None:
            raise AcceptanceFailure("TigerVNC exited before its display became ready")
        ready = subprocess.run(
            [xdpyinfo, "-display", display],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
        if ready.returncode == 0:
            return
        time.sleep(0.1)
    raise AcceptanceFailure("TigerVNC display did not become ready")


def wait_for_port(address: str, port: int, process: subprocess.Popen[bytes]) -> None:
    for _ in range(100):
        if process.poll() is not None:
            raise AcceptanceFailure("TigerVNC exited before its RFB socket became ready")
        try:
            with socket.create_connection((address, port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise AcceptanceFailure("TigerVNC RFB socket did not become ready")


def terminate(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def diagnostics(path: Path) -> str:
    try:
        return path.read_text(errors="replace")[-32_000:]
    except OSError:
        return "<fixture log unavailable>"


def tiger_version(xvnc: str) -> str:
    value = subprocess.run(
        [xvnc, "-version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
    ).stdout.strip()
    return value[:1024]


def verify_report(path: Path = REPORT) -> None:
    try:
        suite = ET.parse(path).getroot()
        exact = {
            key: int(suite.attrib[key])
            for key in ("tests", "skipped", "failures", "errors")
        }
        cases = list(suite.iter("testcase"))
    except (OSError, ET.ParseError, KeyError, TypeError, ValueError) as error:
        raise AcceptanceFailure("TigerVNC acceptance report is unavailable") from error
    if (
        suite.tag != "testsuite"
        or suite.attrib.get("name") != TEST_CLASS
        or exact != {"tests": 1, "skipped": 0, "failures": 0, "errors": 0}
        or len(cases) != 1
        or cases[0].attrib.get("classname") != TEST_CLASS
        or cases[0].attrib.get("name") != TEST_NAME
        or len(suite.findall(".//skipped")) != 0
        or len(suite.findall(".//failure")) != 0
        or len(suite.findall(".//error")) != 0
    ):
        raise AcceptanceFailure("TigerVNC acceptance did not execute exactly once")


def failure_diagnostic(path: Path = REPORT) -> dict[str, object]:
    """Keep owned source lines only; never retain messages, output or fixture secrets."""
    unavailable = {"code": "native_report_unavailable", "frames": []}
    try:
        if path.is_symlink() or not path.is_file() or not 1 <= path.stat().st_size <= 1_048_576:
            return unavailable
        raw = path.read_bytes()
        if len(raw) > 1_048_576 or b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
            return unavailable
        suite = ET.fromstring(raw)
        counts = {key: int(suite.attrib[key]) for key in ("tests", "skipped", "failures", "errors")}
        if any(not 0 <= count <= 1024 for count in counts.values()):
            return unavailable
    except (OSError, ET.ParseError, KeyError, ValueError, TypeError):
        return unavailable
    cases = list(suite.iter("testcase"))
    exact_identity = (
        suite.tag == "testsuite" and suite.attrib.get("name") == TEST_CLASS
        and counts["tests"] == 1 and counts["skipped"] == 0 and len(cases) == 1
        and cases[0].attrib.get("classname") == TEST_CLASS
        and cases[0].attrib.get("name") == TEST_NAME
    )
    if not exact_identity:
        return {"code": "native_report_identity_mismatch", "frames": [], "counts": counts}
    failures = cases[0].findall("failure") + cases[0].findall("error")
    if len(failures) != 1:
        return {"code": "native_failure_unavailable", "frames": [], "counts": counts}
    # A caller-owned frame cannot masquerade as an unrelated owned source file.
    owned_frame = re.compile(
        r"\s*at com\.ersingundem\.larenor\.vnc\."
        r"(VncTigerVncAcceptanceTest|VncAndroidRfbBackend|VncNativeBridge|VncNativeAdapter)"
        r"(?:\$[A-Za-z0-9_$]+)?\.[A-Za-z0-9_$<>]+\(\1\.kt:([0-9]{1,6})\)\s*"
    )
    frames = []
    for line in "".join(failures[0].itertext()).splitlines():
        match = owned_frame.fullmatch(line)
        if match is None or int(match[2]) < 1:
            continue
        frame = {"file": match[1] + ".kt", "line": int(match[2])}
        if frame not in frames:
            frames.append(frame)
        if len(frames) == 8:
            break
    return {"code": "native_test_failed", "frames": frames, "counts": counts}


def acceptance_receipt(
    *, provider_version: str, package_version: str, revision: str
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "provider": "TigerVNC",
        "providerVersion": provider_version,
        "packageVersion": package_version,
        "securityType": "X509Vnc",
        "sourceRevision": revision,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "result": "passed",
        "tests": 1,
        "skipped": 0,
        "failures": 0,
        "errors": 0,
    }


def main() -> int:
    if sys.platform != "linux":
        raise AcceptanceFailure("real TigerVNC acceptance requires an isolated Linux host")
    try:
        revision = source_revision(ROOT)
    except NativeAcceptanceReceiptError as error:
        raise AcceptanceFailure(str(error)) from None
    xvnc = executable("Xtigervnc", "Xvnc")
    vncpasswd = executable("tigervncpasswd", "vncpasswd")
    openssl = executable("openssl")
    ip_command = executable("ip")
    xdpyinfo = executable("xdpyinfo")
    xsetroot = executable("xsetroot")
    xterm = executable("xterm")
    xdotool = executable("xdotool")
    address = discover_address(ip_command)
    port = reserve_port(address)
    display_number = available_display()
    display = f":{display_number}"
    password = secrets.token_urlsafe(6)[:8]
    xvnc_process: subprocess.Popen[bytes] | None = None
    xterm_process: subprocess.Popen[bytes] | None = None

    with tempfile.TemporaryDirectory(prefix="larenor-f61-tigervnc-") as temporary:
        fixture = Path(temporary)
        password_file = fixture / "passwd"
        certificate = fixture / "certificate.pem"
        private_key = fixture / "private-key.pem"
        xvnc_log = fixture / "tigervnc.log"
        xterm_log = fixture / "xterm.log"
        encoded = subprocess.run(
            [vncpasswd, "-f"],
            input=(password + "\n").encode(),
            check=True,
            capture_output=True,
            timeout=10,
        ).stdout
        password_file.write_bytes(encoded)
        password_file.chmod(0o600)
        subprocess.run(
            [
                openssl,
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-sha256",
                "-days",
                "1",
                "-nodes",
                "-keyout",
                str(private_key),
                "-out",
                str(certificate),
                "-subj",
                "/CN=larenor-f61-owned-fixture",
                "-addext",
                f"subjectAltName=IP:{address}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        private_key.chmod(0o600)

        try:
            with xvnc_log.open("wb") as output:
                xvnc_process = subprocess.Popen(
                    [
                        xvnc,
                        display,
                        "-geometry",
                        "800x600",
                        "-depth",
                        "24",
                        "-pixelformat",
                        "RGB888",
                        "-rfbport",
                        str(port),
                        "-interface",
                        address,
                        "-localhost=0",
                        "-SecurityTypes",
                        "X509Vnc",
                        "-PasswordFile",
                        str(password_file),
                        "-X509Cert",
                        str(certificate),
                        "-X509Key",
                        str(private_key),
                        "-AlwaysShared",
                        "-DisconnectClients=0",
                        "-AcceptSetDesktopSize",
                        "-SendCutText",
                        "-AcceptCutText",
                        "-UseBlacklist=0",
                        "-ac",
                        "-noreset",
                        "-nolisten",
                        "tcp",
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            wait_for_display(display, xdpyinfo, xvnc_process)
            wait_for_port(address, port, xvnc_process)
            with xterm_log.open("wb") as output:
                xterm_process = subprocess.Popen(
                    [
                        xterm,
                        "-display",
                        display,
                        "-geometry",
                        "80x24+0+0",
                        "-title",
                        "Larenor-F61-Fixture",
                        "-class",
                        "LarenorF61Fixture",
                        "-e",
                        "/bin/bash",
                        "--noprofile",
                        "--norc",
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            subprocess.run(
                [
                    xdotool,
                    "search",
                    "--sync",
                    "--onlyvisible",
                    "--class",
                    "^LarenorF61Fixture$",
                    "windowfocus",
                ],
                env={**os.environ, "DISPLAY": display},
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            # Keep an X client alive before painting; -noreset also prevents readiness
            # probes closing the last connection from resetting the owned display.
            subprocess.run(
                [
                    xsetroot,
                    "-display",
                    display,
                    "-mod",
                    "8",
                    "8",
                    "-fg",
                    "#315a9c",
                    "-bg",
                    "#f5c842",
                ],
                check=True,
                timeout=10,
            )

            environment = {
                **os.environ,
                "LARENOR_F61_TIGERVNC_ACCEPTANCE": "1",
                "LARENOR_F61_TIGERVNC_HOST": address,
                "LARENOR_F61_TIGERVNC_PORT": str(port),
                "LARENOR_F61_TIGERVNC_PASSWORD": password,
            }
            try:
                gradle = materialized_gradle_command(
                    fixture / "gradle-launcher",
                    project_android=ROOT / "android",
                )
            except AndroidAcceptanceGradleError as error:
                raise AcceptanceFailure(str(error)) from None
            REPORT.unlink(missing_ok=True)
            subprocess.run(
                [
                    *gradle,
                    "--no-daemon",
                    ":app:cleanTestDebugUnitTest",
                    ":app:testDebugUnitTest",
                    "--tests",
                    TEST_CLASS,
                ],
                cwd=ROOT / "android",
                env=environment,
                check=True,
                timeout=900,
            )
            verify_report()
            OUTPUT.mkdir(parents=True, exist_ok=True)
            (OUTPUT / "receipt.json").write_text(
                json.dumps(
                    acceptance_receipt(
                        provider_version=tiger_version(xvnc),
                        package_version=os.environ.get(
                            "TIGERVNC_PACKAGE_VERSION", "unrecorded"
                        ),
                        revision=revision,
                    ),
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            )
        except BaseException as error:
            print(f"F61 TigerVNC acceptance failed: {error}", file=sys.stderr)
            print(json.dumps({
                "sourceRevision": revision,
                "diagnostic": failure_diagnostic(),
            }, sort_keys=True), file=sys.stderr)
            print("--- bounded TigerVNC log ---", file=sys.stderr)
            print(diagnostics(xvnc_log), file=sys.stderr)
            print("--- bounded xterm log ---", file=sys.stderr)
            print(diagnostics(xterm_log), file=sys.stderr)
            raise
        finally:
            terminate(xterm_process)
            terminate(xvnc_process)
            password = ""
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceFailure as failure:
        print(f"F61 TigerVNC acceptance unavailable: {failure}", file=sys.stderr)
        raise SystemExit(2)
