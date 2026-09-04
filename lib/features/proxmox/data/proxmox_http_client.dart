import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Proxmox ships a self-signed TLS certificate by default on every fresh
/// install, so home installations almost always need certificate trust
/// relaxed to connect at all. Isolated to this one helper so no other
/// client in the app is affected by it. The exception is restricted to the
/// configured host and port, including when this transport is used separately.
http.Client buildProxmoxHttpClient({
  required bool allowSelfSigned,
  required Uri server,
  HttpClient? ioClient,
}) {
  final client = ioClient ?? HttpClient();
  client.badCertificateCallback = allowSelfSigned
      ? (cert, host, port) => host == server.host && port == server.port
      : null;
  return IOClient(client);
}
