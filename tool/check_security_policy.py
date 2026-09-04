"""Fail CI when Android backup boundaries or workflow trust boundaries regress.

Uses Python's standard library so this check requires no package downloads.
Runtime/API authorization remains covered by the Flutter regression suite.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
DOMAINS = {"root", "file", "database", "sharedpref", "external"}
DEVICE_DOMAINS = {"device_root", "device_file", "device_database", "device_sharedpref"}


def validate_backup(manifest, legacy, extraction):
    errors = []
    app = ET.fromstring(manifest).find("application")
    if app is None:
        return ["Android application declaration is missing"]
    for key, value in {
        "allowBackup": "false",
        "fullBackupContent": "@xml/backup_rules",
        "dataExtractionRules": "@xml/data_extraction_rules",
    }.items():
        if app.get(ANDROID + key) != value:
            errors.append(f"Android {key} must be {value}")
    if app.get(ANDROID + "debuggable") == "true":
        errors.append("Main manifest must not enable debugging")

    def exclusions(section, name, required):
        if section is None:
            errors.append(f"Missing backup section: {name}")
            return
        if section.findall("include"):
            errors.append(f"Backup includes are forbidden in {name}")
        excluded = {node.get("domain") for node in section.findall("exclude")
                    if node.get("path") in {".", "./"}}
        missing = required - excluded
        if missing:
            errors.append(f"{name} permits backup domains: {', '.join(sorted(missing))}")

    old = ET.fromstring(legacy)
    if old.tag != "full-backup-content":
        errors.append("Invalid legacy backup document")
    exclusions(old, "legacy", DOMAINS)
    new = ET.fromstring(extraction)
    if new.tag != "data-extraction-rules":
        errors.append("Invalid data extraction document")
    for name in ("cloud-backup", "device-transfer"):
        exclusions(new.find(name), name, DOMAINS | DEVICE_DOMAINS)
    return errors


def validate_workflow(text):
    errors = []
    # Actions' YAML is also parsed by GitHub. This deliberately checks only
    # policy-bearing scalar declarations, not arbitrary YAML semantics.
    for match in re.finditer(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", text, re.MULTILINE):
        action = match.group(1).strip("\"'")
        if action.startswith("./"):
            continue
        if not re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", action):
            errors.append("External actions must be pinned to a full commit SHA")
    if not re.search(r"^permissions:\s*\n  contents: read\s*$", text, re.MULTILINE):
        errors.append("Workflow default permissions must be contents: read")
    if re.search(r"\bpull_request_target\s*:", text):
        errors.append("Use unprivileged pull_request for untrusted code")
    if re.search(r"\bwrite-all\b", text):
        errors.append("Broad write permissions are forbidden")
    if "cancel-in-progress: true" not in text:
        errors.append("Superseded runs must be cancelled")
    return errors


def check_repository(root):
    res = root / "android/app/src/main"
    errors = validate_backup(
        (res / "AndroidManifest.xml").read_text(),
        (res / "res/xml/backup_rules.xml").read_text(),
        (res / "res/xml/data_extraction_rules.xml").read_text(),
    )
    for path in sorted((root / ".github/workflows").glob("*.yml")):
        errors.extend(f"{path.name}: {error}" for error in validate_workflow(path.read_text()))
    return errors


if __name__ == "__main__":
    try:
        failures = check_repository(Path(__file__).resolve().parent.parent)
    except (OSError, ET.ParseError) as error:
        failures = [f"Security policy could not be read: {error}"]
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        sys.exit(1)
    print("Android backup exclusions and CI trust policies passed.")
