from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from publish_client_release import (APPLICATION_ID, TOKEN_ENV, Publisher, PublishError,
                                    manifest_from_ci, read_token, server_url)

TOKEN = 'lpub_' + 'P' * 43
APK = b'bounded synthetic payload'
DIGEST = hashlib.sha256(APK).hexdigest()
UPLOAD = '8a4baaad-04de-4a3a-a72e-a8078ce2a144'
METADATA = dict(applicationId=APPLICATION_ID, versionName='2.0', versionCode=20,
                certificateSha256='a' * 64, apkSha256=DIGEST, commit='b' * 40, workflowRun='20')
MANIFEST = manifest_from_ci(METADATA, len(APK), DIGEST, published_at='2026-09-05T12:00:00Z')


@contextmanager
def http_fixture(responder):
    calls = []
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args):
            pass
        def do_PUT(self):
            self.handle_request()
        def do_POST(self):
            self.handle_request()
        def handle_request(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            calls.append((self.command, self.path, dict(self.headers), body))
            result = responder(self, len(calls))
            if result is None:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            status, headers, value = result
            content = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Length', str(len(content)))
            self.send_header('Connection', 'close')
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(content)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def complete(_handler, count):
    if count == 1:
        return 201, {}, dict(state='awaitingUpload', uploadId=UPLOAD, versionCode=20, expiresAt=1788610500)
    if count == 2:
        return 200, {}, dict(state='uploaded', uploadId=UPLOAD, versionCode=20)
    return 200, {}, MANIFEST


class PublishClientReleaseTest(unittest.TestCase):
    def test_three_phase_wire_contract_retains_proxy_prefix_and_opaque_auth(self):
        with http_fixture(complete) as (base, calls):
            result = Publisher(base + '/larenor', TOKEN).publish(MANIFEST, io.BytesIO(APK))
        self.assertEqual(result, dict(state='published', versionCode=20, apkSha256=DIGEST))
        prefix = '/larenor/api/v1/client/releases/20'
        self.assertEqual([(v[0], v[1]) for v in calls], [('PUT', prefix), ('PUT', prefix + '/uploads/' + UPLOAD + '/apk'), ('POST', prefix + '/uploads/' + UPLOAD + '/finalize')])
        self.assertTrue(all(v[2]['Authorization'] == 'Bearer ' + TOKEN for v in calls))
        self.assertEqual(json.loads(calls[0][3]), MANIFEST)
        self.assertEqual(calls[1][3], APK)
        self.assertEqual(calls[1][2]['Content-Length'], str(len(APK)))
        self.assertEqual(calls[2][3], b'')
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_redirect_does_not_forward_authorization_or_reach_trap(self):
        with http_fixture(complete) as (trap, trap_calls):
            with http_fixture(lambda _h, _n: (307, {'Location': trap + '/steal'}, b'secret server body')) as (base, calls):
                with self.assertRaises(PublishError) as caught:
                    Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
                self.assertEqual(caught.exception.code, 'redirect_refused')
                self.assertTrue(caught.exception.outcome_unknown)
                self.assertEqual(len(calls), 1)
            self.assertEqual(trap_calls, [])

    def test_proxy_environment_never_receives_request(self):
        with http_fixture(complete) as (trap, trap_calls):
            with http_fixture(complete) as (base, calls):
                with patch.dict(os.environ, {'HTTP_PROXY': trap, 'HTTPS_PROXY': trap, 'ALL_PROXY': trap, 'NO_PROXY': ''}):
                    Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
                self.assertEqual(len(calls), 3)
            self.assertEqual(trap_calls, [])

    def test_dropped_accepted_connection_reports_unknown_without_retry(self):
        with http_fixture(lambda _h, _n: None) as (base, calls):
            with self.assertRaises(PublishError) as caught:
                Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
            self.assertTrue(caught.exception.outcome_unknown)
            self.assertEqual(len(calls), 1)

    def test_duplicate_or_oversized_server_json_is_unknown_and_redacted(self):
        for body in (b'{"state":"published","state":"uploaded"}', b'x' * 65537, b'private malformed JSON'):
            with self.subTest(body_size=len(body)), http_fixture(lambda _h, _n: (200, {}, body)) as (base, calls):
                with self.assertRaises(PublishError) as caught:
                    Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
                self.assertEqual(caught.exception.code, 'invalid_server_response')
                self.assertTrue(caught.exception.outcome_unknown)
                self.assertNotIn('private', str(caught.exception))
                self.assertEqual(len(calls), 1)

    def test_untrusted_upload_identifier_cannot_change_request_path(self):
        with http_fixture(lambda _h, _n: (201, {}, dict(state='awaitingUpload', versionCode=20, uploadId='../other'))) as (base, calls):
            with self.assertRaises(PublishError):
                Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
            self.assertEqual(len(calls), 1)

    def test_explicit_rerun_can_finalize_uploaded_stage_without_resending_apk(self):
        def responder(_h, n):
            return (200, {}, dict(state='uploaded', uploadId=UPLOAD, versionCode=20)) if n == 1 else (200, {}, MANIFEST)
        with http_fixture(responder) as (base, calls):
            result = Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))
            self.assertEqual(result['state'], 'published')
            self.assertEqual([v[0] for v in calls], ['PUT', 'POST'])

    def test_existing_identical_release_is_idempotent_no_upload(self):
        with http_fixture(lambda _h, _n: (200, {}, dict(state='published', release=MANIFEST))) as (base, calls):
            self.assertEqual(Publisher(base, TOKEN).publish(MANIFEST, io.BytesIO(APK))['state'], 'alreadyPublished')
            self.assertEqual(len(calls), 1)

    def test_private_token_file_and_ordinary_account_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / 'publish-token'
            token.write_text(TOKEN + '\n')
            token.chmod(0o600)
            self.assertEqual(read_token(token, {}), TOKEN)
            token.chmod(0o644)
            with self.assertRaises(PublishError):
                read_token(token, {})
            token.chmod(0o600)
            with self.assertRaises(PublishError):
                read_token(token, {TOKEN_ENV: TOKEN})
            token.write_text(TOKEN + '\n\n')
            with self.assertRaises(PublishError):
                read_token(token, {})
            link = Path(directory) / 'link'
            link.symlink_to(token)
            with self.assertRaises(OSError):
                read_token(link, {})
        with self.assertRaises(PublishError):
            read_token(None, {TOKEN_ENV: 'A' * 43})
        self.assertEqual(read_token(None, {TOKEN_ENV: TOKEN}), TOKEN)

    def test_url_boundaries_reject_ambiguous_authority_or_path(self):
        for value in ('https://user:secret@host', 'https://host/?token=secret', 'https://host/#fragment',
                      'https://host/a/%2e%2e', 'https://host/a/../b', 'https://host/a\\b', 'ftp://host',
                      'https://host:65536', 'https://host/a\nb'):
            with self.subTest(value=value), self.assertRaises(PublishError):
                server_url(value)
        self.assertEqual(server_url('http://[::1]:8080/prefix').hostname, '::1')

    def test_actual_apk_hash_is_required_before_any_publish_call(self):
        with self.assertRaises(PublishError) as caught:
            manifest_from_ci(METADATA, len(APK), 'f' * 64)
        self.assertEqual(caught.exception.code, 'apk_hash_mismatch')
        with http_fixture(complete) as (base, calls), tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            apk = directory / 'client.apk'
            apk.write_bytes(b'changed')
            metadata = directory / 'metadata.json'
            metadata.write_text(json.dumps(METADATA))
            env = os.environ | {TOKEN_ENV: TOKEN}
            result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'publish_client_release.py'),
                                     '--server', base, '--apk', str(apk), '--metadata', str(metadata)],
                                    capture_output=True, env=env, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout), dict(state='rejected', error='apk_hash_mismatch'))
            self.assertEqual(result.stderr, b'')
            self.assertNotIn(TOKEN.encode(), result.stdout)
            self.assertEqual(calls, [])

    def test_invalid_manifest_text_rejected_locally_and_unicode_notes_fit_wire_bound(self):
        for notes in ('\ud800', 'hidden\x00control', 'delete\x7f'):
            with self.subTest(notes=repr(notes)), self.assertRaises(PublishError) as caught:
                manifest_from_ci(METADATA, len(APK), DIGEST, notes=notes)
            self.assertEqual(caught.exception.code, 'invalid_metadata')
        for version_name in ('  ', '\udfff', '\x00'):
            with self.subTest(version_name=repr(version_name)), self.assertRaises(PublishError):
                manifest_from_ci(METADATA | {'versionName': version_name}, len(APK), DIGEST)
        with self.assertRaises(PublishError):
            manifest_from_ci(METADATA, len(APK), DIGEST, published_at='2026-09-05 12:00:00Z')
        expected = manifest_from_ci(METADATA, len(APK), DIGEST, notes='🎵' * 12000)
        def respond(_handler, count):
            return complete(_handler, count) if count < 3 else (200, {}, expected)
        with http_fixture(respond) as (base, calls):
            self.assertEqual(Publisher(base, TOKEN).publish(expected, io.BytesIO(APK))['state'], 'published')
            self.assertLess(len(calls[0][3]), 65536)
            self.assertEqual(json.loads(calls[0][3])['releaseNotes'], '🎵' * 12000)

    def test_unknown_arguments_never_echo_secrets(self):
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'publish_client_release.py'),
                                 '--token', TOKEN], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['error'], 'invalid_arguments')


if __name__ == '__main__':
    unittest.main()
