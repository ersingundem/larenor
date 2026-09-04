import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/proxmox_http_client.dart';

class _InspectableHttpClient extends Fake implements HttpClient {
  bool Function(X509Certificate, String, int)? certificateCheck;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) {
    certificateCheck = value;
  }

  @override
  void close({bool force = false}) {}
}

class _Certificate extends Fake implements X509Certificate {}

void main() {
  test('self-signed trust is restricted to the configured host and port', () {
    final io = _InspectableHttpClient();
    final client = buildProxmoxHttpClient(
      allowSelfSigned: true,
      server: Uri.parse('https://proxmox.local:8006'),
      ioClient: io,
    );
    addTearDown(client.close);
    final certificate = _Certificate();
    expect(io.certificateCheck!(certificate, 'proxmox.local', 8006), isTrue);
    expect(io.certificateCheck!(certificate, 'another.local', 8006), isFalse);
    expect(io.certificateCheck!(certificate, 'proxmox.local', 443), isFalse);
    expect(
      io.certificateCheck!(certificate, 'sub.proxmox.local', 8006),
      isFalse,
    );
  });

  test('strict TLS does not install any certificate exception', () {
    final io = _InspectableHttpClient();
    final client = buildProxmoxHttpClient(
      allowSelfSigned: false,
      server: Uri.parse('https://proxmox.local:8006'),
      ioClient: io,
    );
    addTearDown(client.close);
    expect(io.certificateCheck, isNull);
  });
}
