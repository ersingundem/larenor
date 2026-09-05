import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import pytest

from larenor_server.errors import ApiError
from larenor_server.releases.verifier import APKSIG_SHA256, JavaApkVerifier, compare_verified

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'android/app/src/test/resources/updater/aosp-signed-apk.fixture'
FIXTURE_SHA = '020b4e92bd80c016f960ab98952afa0975dca0a0a6612103514d867351d23559'


@pytest.fixture(scope='module')
def crypto(tmp_path_factory):
    configured = os.environ.get('LARENOR_TEST_APKSIG_JAR')
    assert configured, 'Set LARENOR_TEST_APKSIG_JAR to the pinned official apksig 9.1.0 artifact; crypto tests cannot be skipped.'
    jar = Path(configured).resolve()
    assert hashlib.sha256(jar.read_bytes()).hexdigest() == APKSIG_SHA256
    java = shutil.which('java')
    javac = shutil.which('javac')
    assert java and javac, 'A Java 17+ JDK is required for the actual APK verification tests.'
    classes = tmp_path_factory.mktemp('apk-verifier').resolve()
    compile_result = subprocess.run([javac, '-cp', str(jar), '-d', str(classes),
                                    str(ROOT / 'server/larenor_server/releases/java/VerifyApk.java')],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    assert compile_result.returncode == 0, 'The release verifier helper must compile with the pinned library.'
    assert hashlib.sha256(FIXTURE.read_bytes()).hexdigest() == FIXTURE_SHA
    return JavaApkVerifier(Path(java).absolute(), jar, classes)


def test_actual_aosp_signature_and_binary_manifest_are_verified(crypto):
    result = crypto.verify(FIXTURE)
    assert result == dict(schemaVersion=1, verified=True, applicationId='android.appsecurity.cts.tinyapp',
                         versionCode=10, versionName='1.0', minSdk=23, debuggable=False,
                         certificateSha256='fb5dbd3c669af9fc236c6991e6387b7f11ff0590997f22d0f5c74ff40e04fca8')
    compare_verified(result, result, result['certificateSha256'])
    with pytest.raises(ApiError, match='release_verification_failed'):
        compare_verified(result | {'applicationId': 'com.ersingundem.larenor'}, result, result['certificateSha256'])
    with pytest.raises(ApiError, match='release_verification_failed'):
        compare_verified(result, result, 'f' * 64)


def test_actual_apk_tampering_cannot_be_hidden_by_manifest_metadata(crypto, tmp_path):
    tampered = tmp_path / 'tampered.apk'
    with zipfile.ZipFile(FIXTURE) as source, zipfile.ZipFile(tampered, 'w') as output:
        for item in source.infolist():
            value = source.read(item)
            if item.filename == 'classes.dex':
                value = value[:-1] + bytes([value[-1] ^ 1])
            output.writestr(item, value)
    with pytest.raises(ApiError, match='release_verification_failed'):
        crypto.verify(tampered)


def test_actual_malformed_archive_and_duplicate_manifest_rejected(crypto, tmp_path):
    invalid = tmp_path / 'invalid.apk'
    invalid.write_bytes(b'not an APK')
    with pytest.raises(ApiError, match='release_verification_failed'):
        crypto.verify(invalid)
    duplicate = tmp_path / 'duplicate.apk'
    with zipfile.ZipFile(FIXTURE) as source, zipfile.ZipFile(duplicate, 'w') as output:
        with pytest.warns(UserWarning):
            for _ in range(2):
                output.writestr('AndroidManifest.xml', source.read('AndroidManifest.xml'))
    with pytest.raises(ApiError, match='release_verification_failed'):
        crypto.verify(duplicate)


def test_wrong_library_pin_or_missing_helper_fail_closed(crypto, tmp_path):
    jar = tmp_path / 'changed.jar'
    jar.write_bytes(b'not approved library')
    with pytest.raises(ApiError, match='release_verifier_unavailable'):
        JavaApkVerifier(crypto.java, jar, crypto.classes).verify(FIXTURE)
    with pytest.raises(ApiError, match='release_verifier_unavailable'):
        JavaApkVerifier(crypto.java, crypto.jar, tmp_path / 'missing-classes').verify(FIXTURE)
