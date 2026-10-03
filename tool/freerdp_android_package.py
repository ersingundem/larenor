#!/usr/bin/env python3
"""Verify and receipt the exact FreeRDP Android native package input."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import tarfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "android/freerdp-native.lock.json"
KOTLIN_PATH = ROOT / (
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/"
    "RdpFreeRdpEngine.kt"
)
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
ABI_MACHINE = {"arm64-v8a": 183, "x86_64": 62}
FREERDP_CLASS = "com/freerdp/freerdpcore/services/LibFreeRDP.class"
EVENT_LISTENER_CLASS = (
    "com/freerdp/freerdpcore/services/LibFreeRDP$EventListener.class"
)
REQUIRED_FREERDP_API = (
    ("sendRelativeCursorEvent", "(JIII)Z"),
    ("isRelativeMouseInputSupported", "(J)Z"),
    ("sendMonitorLayout", "(JII)Z"),
    ("sendMonitorLayout", "(JIIII)Z"),
)
REQUIRED_EVENT_LISTENER_API = (("OnDisplayControlReady", "(J)V"),)


class PackageError(ValueError):
    pass


def _require(condition, code):
    if not condition:
        raise PackageError(code)


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git_blob(data):
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data).hexdigest()


def load_lock(path=LOCK_PATH):
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_lock") from error
    _require(set(value) == {
        "schemaVersion", "engineRevision", "source", "reviewedFiles",
        "patches",
        "toolchain", "supportedAbis", "jniSchema", "defaultChannels",
        "requiredLibraries", "requiredClasses", "requiredJniSymbols",
        "requiredNativeEvidence",
    }, "invalid_lock")
    _require(value["schemaVersion"] == 1 and value["jniSchema"] == 2,
             "invalid_lock")
    source = value["source"]
    _require(set(source) == {"version", "commit", "url", "sha256"},
             "invalid_lock")
    _require(source["version"] == "3.31.1", "invalid_lock")
    _require(HEX40.fullmatch(source["commit"] or ""), "invalid_lock")
    _require(HEX64.fullmatch(source["sha256"] or ""), "invalid_lock")
    _require(source["url"] == (
        "https://github.com/FreeRDP/FreeRDP/releases/download/3.31.1/"
        "freerdp-3.31.1.tar.gz"
    ), "invalid_lock")
    reviewed = value["reviewedFiles"]
    _require(type(reviewed) is dict and len(reviewed) == 12 and
             all(type(name) is str and HEX40.fullmatch(digest or "")
                 for name, digest in reviewed.items()), "invalid_lock")
    patches = value["patches"]
    try:
        expected_patches = [
            {
                "path": "android/freerdp-certificate-pem.patch",
                "sha256": _sha256(ROOT / "android/freerdp-certificate-pem.patch"),
            },
            {
                "path": "android/freerdp-clipboard-utf8.patch",
                "sha256": _sha256(ROOT / "android/freerdp-clipboard-utf8.patch"),
            },
            {
                "path": "android/freerdp-display-pointer-v2.patch",
                "sha256": _sha256(ROOT / "android/freerdp-display-pointer-v2.patch"),
            },
        ]
    except OSError as error:
        raise PackageError("invalid_lock") from error
    _require(
        type(patches) is list
        and len(patches) == 3
        and patches == expected_patches,
        "invalid_lock",
    )
    _require(value["toolchain"] == {
        "java": "17", "androidPlatform": "37.0",
        "androidBuildTools": "37.0.0", "ndk": "29.0.13113456",
        "cmake": "4.1.2", "gradle": "9.6.1",
    }, "invalid_lock")
    _require(value["supportedAbis"] == ["arm64-v8a", "x86_64"],
             "invalid_lock")
    _require(value["defaultChannels"] == [], "invalid_lock")
    _require(value["requiredLibraries"] == [
        "libfreerdp-android.so", "libfreerdp-client3.so",
        "libfreerdp3.so", "libwinpr3.so",
    ], "invalid_lock")
    _require(value["requiredClasses"] == [
        FREERDP_CLASS,
        EVENT_LISTENER_CLASS,
        "com/freerdp/freerdpcore/services/LibFreeRDP$UIEventListener.class",
        "com/freerdp/freerdpcore/application/GlobalApp.class",
        "com/freerdp/freerdpcore/application/SessionState.class",
    ], "invalid_lock")
    _require(value["requiredJniSymbols"] == ["JNI_OnLoad"], "invalid_lock")
    _require(
        value["requiredNativeEvidence"]
        == [
            "JNI_OnLoad",
            "ConvertWCharNToUtf8Alloc",
            "freerdp_input_send_rel_mouse_event",
            (
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
                "freerdp_1send_1relative_1cursor_1event"
            ),
            (
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
                "freerdp_1is_1relative_1mouse_1input_1supported"
            ),
            (
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
                "freerdp_1send_1monitor_1layout"
            ),
            "OnDisplayControlReady",
        ],
        "invalid_lock",
    )
    kotlin = KOTLIN_PATH.read_text()
    for expected in (
        f'const val VERSION = "{source["version"]}"',
        f'const val SOURCE_COMMIT = "{source["commit"]}"',
        f'const val SOURCE_SHA256 = "{source["sha256"]}"',
        f'const val ENGINE_REVISION = "{value["engineRevision"]}"',
        f'identity.jniSchema == {value["jniSchema"]}',
    ):
        _require(expected in kotlin, "kotlin_lock_mismatch")
    return value


def verify_source(archive, lock):
    _require(archive.is_file() and _sha256(archive) == lock["source"]["sha256"],
             "source_digest_mismatch")
    prefix = f'freerdp-{lock["source"]["version"]}/'
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            names = bundle.getnames()
            _require(names and all(
                PurePosixPath(name).parts and
                PurePosixPath(name).parts[0] == prefix[:-1] and
                ".." not in PurePosixPath(name).parts and
                not PurePosixPath(name).is_absolute()
                for name in names
            ), "unsafe_source_archive")
            for relative, expected in lock["reviewedFiles"].items():
                member = bundle.getmember(prefix + relative)
                _require(member.isfile() and member.size <= 2 * 1024 * 1024,
                         "invalid_reviewed_source")
                stream = bundle.extractfile(member)
                _require(stream is not None and _git_blob(stream.read()) == expected,
                         "reviewed_source_mismatch")
    except (tarfile.TarError, KeyError, OSError) as error:
        raise PackageError("invalid_source_archive") from error


def _elf_machine(data):
    _require(len(data) >= 20 and data[:4] == b"\x7fELF" and data[5] in (1, 2),
             "invalid_native_library")
    order = "<" if data[5] == 1 else ">"
    return struct.unpack(order + "H", data[18:20])[0]


def verify_certificate_patch(source):
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_certificate_patch") from error
    function = text.find("static BOOL android_pre_connect(freerdp* instance)")
    following = text.find("static BOOL android_post_connect", function + 1)
    marker = (
        "if (!freerdp_settings_set_bool(settings, "
        "FreeRDP_CertificateCallbackPreferPEM, TRUE))\n\t\treturn FALSE;"
    )
    position = text.find(marker)
    declaration = text.find(
        "rdpSettings* settings = instance->context->settings;", function
    )
    subscription = text.find(
        "int rc = PubSub_SubscribeChannelConnected", function
    )
    _require(
        function >= 0
        and following > function
        and text.count(marker) == 1
        and function < declaration < position < subscription < following,
        "invalid_certificate_patch",
    )


def verify_clipboard_patch(source):
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_clipboard_patch") from error
    start = text.find(
        "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
        "freerdp_1send_1clipboard_1data"
    )
    following = text.find("static BOOL android_is_image_mime_supported", start + 1)
    function = text[start:following] if start >= 0 and following > start else ""
    required = (
        "#define ANDROID_CLIPBOARD_TEXT_MAX_BYTES (64U * 1024U)",
        "#include <winpr/crt.h>",
        "#include <winpr/string.h>",
        "GetStringLength(env, jdata)",
        "GetStringChars(env, jdata, nullptr)",
        "android_copy_clipboard_utf16(chars, wide_length, wide)",
        "ConvertWCharNToUtf8Alloc(wide, (size_t)wide_length, &data_length)",
        "data_length > ANDROID_CLIPBOARD_TEXT_MAX_BYTES",
        'android_push_clipboard_event(inst, data, data_length, "text/plain")',
        "SecureZeroMemory(data, data_length + 1U)",
        "SecureZeroMemory(wide, ((size_t)wide_length + 1U) * sizeof(WCHAR))",
        "ReleaseStringChars(env, jdata, chars)",
    )
    helper_start = text.find("static BOOL android_copy_clipboard_utf16")
    helper_end = start
    helper = text[helper_start:helper_end] if 0 <= helper_start < helper_end else ""
    event_source = source.with_name("android_event.c")
    try:
        event_text = event_source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_clipboard_patch") from error
    event_start = event_text.find("static void android_event_clipboard_free")
    event_following = event_text.find("BOOL android_event_queue_init", event_start + 1)
    event_free = (
        event_text[event_start:event_following]
        if event_start >= 0 and event_following > event_start
        else ""
    )
    _require(
        function
        and all(marker in text if marker.startswith("#") else marker in function
                for marker in required)
        and "value == 0" in helper
        and "value >= 0xD800U" in helper
        and "value <= 0xDBFFU" in helper
        and "chars[x + 1] < 0xDC00U" in helper
        and "chars[x + 1] > 0xDFFFU" in helper
        and "value >= 0xDC00U" in helper
        and "value <= 0xDFFFU" in helper
        and "GetStringUTFChars" not in function
        and "GetStringUTFLength" not in function
        and 'send_clipboard_data: (%s)' not in function
        and function.find("GetStringChars")
        < function.find("ConvertWCharNToUtf8Alloc")
        < function.find("android_push_clipboard_event")
        < function.find("SecureZeroMemory(data")
        and "SecureZeroMemory(event->data, event->data_length)" in event_free
        and event_free.find("SecureZeroMemory(event->data")
        < event_free.find("free(event->data)"),
        "invalid_clipboard_patch",
    )


def verify_display_pointer_patch(source_root):
    root = source_root.resolve()
    base = root / "client/Android/Studio/freeRDPCore/src/main"
    paths = {
        "java": base / "java/com/freerdp/freerdpcore/services/LibFreeRDP.java",
        "native": base / "cpp/android_freerdp.c",
        "event_h": base / "cpp/android_event.h",
        "event_c": base / "cpp/android_event.c",
        "disp_h": base / "cpp/android_disp.h",
        "disp_c": base / "cpp/android_disp.c",
        "context_h": base / "cpp/android_freerdp.h",
    }
    try:
        source = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}
    except OSError as error:
        raise PackageError("invalid_display_pointer_patch") from error

    native = source["native"]
    relative_start = native.find(
        "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
        "freerdp_1send_1relative_1cursor_1event"
    )
    query_symbol = (
        "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
        "freerdp_1is_1relative_1mouse_1input_1supported"
    )
    query_start = native.find(query_symbol)
    following = native.find("static jboolean android_push_clipboard_event", query_start)
    relative = native[relative_start:query_start]
    query = native[query_start:following]
    monitor_start = native.find(
        "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
        "freerdp_1send_1monitor_1layout"
    )
    monitor_end = native.find("JNIEXPORT jstring JNICALL", monitor_start)
    monitor = native[monitor_start:monitor_end]
    required_java = (
        "public static boolean sendRelativeCursorEvent(long inst, int deltaX, int deltaY, int flags)",
        "public static boolean isRelativeMouseInputSupported(long inst)",
        "public static boolean sendMonitorLayout(long inst, int width, int height)",
        "public static boolean sendMonitorLayout(long inst, int width, int height,",
        "int desktopScaleFactor, int deviceScaleFactor)",
        "SessionState state = GlobalApp.getSession(inst);",
        "screen.isCustomScale() ? screen.getScaleDesktop() : screen.getScalePreset();",
        "screen.isCustomScale() ? screen.getScaleDevice() : screen.getScalePreset();",
        "private static void OnDisplayControlReady(long inst)",
        "listener.OnDisplayControlReady(inst);",
        "default void OnDisplayControlReady(long instance)",
    )
    event_h = source["event_h"]
    event_c = source["event_c"]
    disp_h = source["disp_h"]
    disp_c = source["disp_c"]
    context_h = source["context_h"]
    ready_handler = disp_c.find("static UINT android_DisplayControlCaps(")
    ready_assign = disp_c.find("afc->dispReady = TRUE;", ready_handler)
    ready_callback = disp_c.find(
        'freerdp_callback("OnDisplayControlReady", "(J)V",', ready_assign
    )
    ready_return = disp_c.find("return CHANNEL_RC_OK;", ready_callback)
    init_start = disp_c.find("BOOL android_disp_init(")
    init_end = disp_c.find("BOOL android_disp_uninit(", init_start)
    init = disp_c[init_start:init_end]
    uninit_start = init_end
    uninit_end = disp_c.find("BOOL android_disp_send_monitor_layout(", uninit_start)
    uninit = disp_c[uninit_start:uninit_end]
    send = disp_c[uninit_end:]
    _require(
        all(marker in source["java"] for marker in required_java)
        and relative_start >= 0
        and query_start > relative_start
        and native.count(query_symbol) == 1
        and following > query_start
        and "INT16_MIN" in relative
        and "INT16_MAX" in relative
        and "ANDROID_RELATIVE_POINTER_FLAGS" in relative
        and "android_event_relative_cursor_new" in relative
        and "android_push_event(inst, event)" in relative
        and "freerdp_input_send_rel_mouse_event" not in relative
        and "FreeRDP_HasRelativeMouseEvent" in query
        and "freerdp_settings_get_bool" in query
        and "EVENT_TYPE_RELATIVE_CURSOR 6" in event_h
        and "INT16 xDelta" in event_h
        and "INT16 yDelta" in event_h
        and "android_event_relative_cursor_new" in event_h
        and "case EVENT_TYPE_RELATIVE_CURSOR" in event_c
        and "freerdp_input_send_rel_mouse_event" in event_c
        and "android_event_relative_cursor_free" in event_c
        and event_c.find("freerdp_input_send_rel_mouse_event")
        < event_c.find("android_event_relative_cursor_free")
        and "UINT32 desktopScaleFactor" in disp_h
        and "UINT32 deviceScaleFactor" in disp_h
        and monitor_start >= 0
        and monitor_end > monitor_start
        and "desktopScaleFactor < 100" in monitor
        and "desktopScaleFactor > 500" in monitor
        and monitor.count("(width & 1) != 0") == 1
        and "deviceScaleFactor != 100" in monitor
        and "deviceScaleFactor != 140" in monitor
        and "deviceScaleFactor != 180" in monitor
        and "android_disp_send_monitor_layout" in monitor
        and "layout.DesktopScaleFactor = desktopScaleFactor;" in disp_c
        and "layout.DeviceScaleFactor = deviceScaleFactor;" in disp_c
        and "freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor)" not in disp_c
        and "freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor)" not in disp_c
        and disp_c.count("desktopScaleFactor < 100") == 1
        and disp_c.count("(width & 1) != 0") == 1
        and disp_c.count("deviceScaleFactor != 100") == 1
        and "#include <stdint.h>" in disp_c
        and '#include "android_jni_callback.h"' in disp_c
        and "BOOL dispReady;" in context_h
        and "UINT32 dispMaxNumMonitors;" in context_h
        and "UINT32 dispMaxMonitorAreaFactorA;" in context_h
        and "UINT32 dispMaxMonitorAreaFactorB;" in context_h
        and ready_handler >= 0
        and "disp->custom" in disp_c[ready_handler:ready_assign]
        and "afc->disp != disp" in disp_c[ready_handler:ready_assign]
        and "maxNumMonitors == 0" in disp_c[ready_handler:ready_assign]
        and "maxMonitorAreaFactorA == 0" in disp_c[ready_handler:ready_assign]
        and "maxMonitorAreaFactorB == 0" in disp_c[ready_handler:ready_assign]
        and ready_handler < ready_assign < ready_callback < ready_return
        and "(jlong)afc->common.context.instance" in disp_c[
            ready_callback:ready_return
        ]
        and disp_c.count('freerdp_callback("OnDisplayControlReady"') == 1
        and "disp->DisplayControlCaps = android_DisplayControlCaps;" in init
        and 'freerdp_callback("OnDisplayControlReady"' not in init
        and "afc->dispReady = FALSE;" in init
        and "afc->dispMaxNumMonitors = 0;" in init
        and "afc->dispMaxMonitorAreaFactorA = 0;" in init
        and "afc->dispMaxMonitorAreaFactorB = 0;" in init
        and "afc->dispReady = FALSE;" in uninit
        and "afc->dispMaxNumMonitors = 0;" in uninit
        and "afc->dispMaxMonitorAreaFactorA = 0;" in uninit
        and "afc->dispMaxMonitorAreaFactorB = 0;" in uninit
        and "if (!afc->dispReady" in send
        and "UINT64_MAX / afc->dispMaxMonitorAreaFactorB" in send
        and "(UINT64)width * height" in send
        and "if (requestedArea > maximumArea)" in send,
        "invalid_display_pointer_patch",
    )


class _ClassReader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, size):
        _require(0 <= size <= len(self.data) - self.offset, "invalid_java_contract")
        value = self.data[self.offset:self.offset + size]
        self.offset += size
        return value

    def u1(self):
        return self.take(1)[0]

    def u2(self):
        return struct.unpack(">H", self.take(2))[0]

    def u4(self):
        return struct.unpack(">I", self.take(4))[0]


def _skip_class_attributes(reader, count):
    _require(count <= 65535, "invalid_java_contract")
    for _ in range(count):
        reader.u2()
        reader.take(reader.u4())


def _skip_class_members(reader, count):
    _require(count <= 65535, "invalid_java_contract")
    for _ in range(count):
        reader.u2()
        reader.u2()
        reader.u2()
        _skip_class_attributes(reader, reader.u2())


def _class_methods(data):
    _require(type(data) is bytes and 16 <= len(data) <= 16 * 1024 * 1024,
             "invalid_java_contract")
    reader = _ClassReader(data)
    _require(reader.u4() == 0xCAFEBABE, "invalid_java_contract")
    reader.u2()
    reader.u2()
    constant_count = reader.u2()
    _require(1 < constant_count <= 65535, "invalid_java_contract")
    constants = [None] * constant_count
    index = 1
    while index < constant_count:
        tag = reader.u1()
        if tag == 1:
            size = reader.u2()
            try:
                constants[index] = reader.take(size).decode("utf-8")
            except UnicodeDecodeError as error:
                raise PackageError("invalid_java_contract") from error
        elif tag in (3, 4):
            reader.take(4)
        elif tag in (5, 6):
            reader.take(8)
            index += 1
            _require(index < constant_count, "invalid_java_contract")
        elif tag in (7, 8, 16, 19, 20):
            reader.take(2)
        elif tag in (9, 10, 11, 12, 17, 18):
            reader.take(4)
        elif tag == 15:
            reader.take(3)
        else:
            raise PackageError("invalid_java_contract")
        index += 1
    reader.u2()
    reader.u2()
    reader.u2()
    reader.take(reader.u2() * 2)
    _skip_class_members(reader, reader.u2())
    methods = set()
    for _ in range(reader.u2()):
        access = reader.u2()
        name_index = reader.u2()
        descriptor_index = reader.u2()
        _require(
            0 < name_index < constant_count
            and 0 < descriptor_index < constant_count
            and type(constants[name_index]) is str
            and type(constants[descriptor_index]) is str,
            "invalid_java_contract",
        )
        methods.add((constants[name_index], constants[descriptor_index], access))
        _skip_class_attributes(reader, reader.u2())
    _skip_class_attributes(reader, reader.u2())
    _require(reader.offset == len(data), "invalid_java_contract")
    return methods


def _verify_freerdp_api(data):
    methods = _class_methods(data)
    for name, descriptor in REQUIRED_FREERDP_API:
        matching = [
            access for method, value, access in methods
            if method == name and value == descriptor
        ]
        _require(
            len(matching) == 1
            and matching[0] & 0x0001
            and matching[0] & 0x0008,
            "missing_java_contract",
        )


def _verify_event_listener_api(data):
    methods = _class_methods(data)
    for name, descriptor in REQUIRED_EVENT_LISTENER_API:
        matching = [
            access for method, value, access in methods
            if method == name and value == descriptor
        ]
        _require(
            len(matching) == 1
            and matching[0] & 0x0001
            and not matching[0] & 0x0008,
            "missing_java_contract",
        )

def package_receipt(aar, abi, lock):
    _require(abi in lock["supportedAbis"], "unsupported_abi")
    _require(aar.is_file() and aar.stat().st_size <= 512 * 1024 * 1024,
             "invalid_aar")
    prefix = f"jni/{abi}/"
    try:
        with zipfile.ZipFile(aar) as bundle:
            names = bundle.namelist()
            _require("AndroidManifest.xml" in names and "classes.jar" in names,
                     "invalid_aar")
            classes = bundle.read("classes.jar")
            with zipfile.ZipFile(__import__("io").BytesIO(classes)) as jar:
                class_names = set(jar.namelist())
                _require(all(name in class_names for name in lock["requiredClasses"]),
                         "missing_java_contract")
                _verify_freerdp_api(jar.read(FREERDP_CLASS))
                _verify_event_listener_api(jar.read(EVENT_LISTENER_CLASS))
            native = [name for name in names if name.startswith("jni/") and
                      name.endswith(".so")]
            _require(native and all(name.startswith(prefix) for name in native),
                     "mixed_abi_aar")
            entries = []
            by_name = {PurePosixPath(name).name: name for name in native}
            for required in lock["requiredLibraries"]:
                _require(required in by_name, "missing_native_library")
                data = bundle.read(by_name[required])
                _require(_elf_machine(data) == ABI_MACHINE[abi],
                         "wrong_native_architecture")
                entries.append({
                    "name": required,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                })
            primary = bundle.read(by_name["libfreerdp-android.so"])
            _require(all(symbol.encode() in primary for symbol in lock["requiredJniSymbols"]),
                     "missing_jni_symbol")
            _require(
                all(
                    evidence.encode() in primary
                    for evidence in lock["requiredNativeEvidence"]
                ),
                "missing_native_evidence",
            )
    except (zipfile.BadZipFile, KeyError, OSError) as error:
        raise PackageError("invalid_aar") from error
    return {
        "schemaVersion": 1,
        "engineRevision": lock["engineRevision"],
        "jniSchema": lock["jniSchema"],
        "sourceCommit": lock["source"]["commit"],
        "sourceSha256": lock["source"]["sha256"],
        "abi": abi,
        "aarSha256": _sha256(aar),
        "classesSha256": hashlib.sha256(classes).hexdigest(),
        "patches": lock["patches"],
        "defaultChannels": [],
        "libraries": entries,
    }


def verify_install(aar, receipt_path, lock):
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_receipt") from error
    _require(type(receipt) is dict and receipt.get("abi") in lock["supportedAbis"],
             "invalid_receipt")
    _require(receipt == package_receipt(aar, receipt["abi"], lock),
             "receipt_mismatch")


def _verify_receipt_contract(receipt, lock):
    _require(
        type(receipt) is dict
        and set(receipt) == {
            "schemaVersion",
            "engineRevision",
            "jniSchema",
            "sourceCommit",
            "sourceSha256",
            "abi",
            "aarSha256",
            "classesSha256",
            "patches",
            "defaultChannels",
            "libraries",
        }
        and receipt["schemaVersion"] == 1
        and receipt["engineRevision"] == lock["engineRevision"]
        and receipt["jniSchema"] == lock["jniSchema"]
        and receipt["sourceCommit"] == lock["source"]["commit"]
        and receipt["sourceSha256"] == lock["source"]["sha256"]
        and receipt["abi"] in lock["supportedAbis"]
        and type(receipt["aarSha256"]) is str
        and HEX64.fullmatch(receipt["aarSha256"] or "")
        and type(receipt["classesSha256"]) is str
        and HEX64.fullmatch(receipt["classesSha256"] or "")
        and receipt["patches"] == lock["patches"]
        and receipt["defaultChannels"] == [],
        "receipt_mismatch",
    )
    libraries = receipt["libraries"]
    _require(
        type(libraries) is list
        and all(
            type(item) is dict
            and set(item) == {"name", "size", "sha256"}
            and type(item["size"]) is int
            and item["size"] > 0
            and type(item["sha256"]) is str
            and HEX64.fullmatch(item["sha256"] or "")
            for item in libraries
        )
        and [item["name"] for item in libraries] == lock["requiredLibraries"],
        "receipt_mismatch",
    )


def verify_apk(apk, receipt_path, lock):
    try:
        receipt = json.loads(receipt_path.read_text())
        _verify_receipt_contract(receipt, lock)
        with zipfile.ZipFile(apk) as bundle:
            for item in receipt["libraries"]:
                data = bundle.read(f'lib/{receipt["abi"]}/{item["name"]}')
                _require(hashlib.sha256(data).hexdigest() == item["sha256"],
                         "apk_library_mismatch")
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        raise PackageError("invalid_apk") from error


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-lock")
    source = sub.add_parser("verify-source")
    source.add_argument("archive", type=Path)
    patch = sub.add_parser("verify-patch")
    patch.add_argument("source", type=Path)
    receipt = sub.add_parser("receipt")
    receipt.add_argument("aar", type=Path)
    receipt.add_argument("--abi", required=True)
    receipt.add_argument("--output", type=Path, required=True)
    install = sub.add_parser("verify-install")
    install.add_argument("aar", type=Path)
    install.add_argument("receipt", type=Path)
    apk = sub.add_parser("verify-apk")
    apk.add_argument("apk", type=Path)
    apk.add_argument("receipt", type=Path)
    args = parser.parse_args(argv)
    try:
        lock = load_lock()
        if args.command == "verify-source":
            verify_source(args.archive, lock)
        elif args.command == "verify-patch":
            native = args.source / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/"
                "android_freerdp.c"
            )
            verify_certificate_patch(native)
            verify_clipboard_patch(native)
            verify_display_pointer_patch(args.source)
        elif args.command == "receipt":
            value = package_receipt(args.aar, args.abi, lock)
            args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        elif args.command == "verify-install":
            verify_install(args.aar, args.receipt, lock)
        elif args.command == "verify-apk":
            verify_apk(args.apk, args.receipt, lock)
        return 0
    except PackageError as error:
        print(f"FreeRDP package error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
