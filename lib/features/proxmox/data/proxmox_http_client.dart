import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Proxmox ships a self-signed TLS certificate by default on every fresh
/// install, so home installations almost always need certificate trust
/// relaxed to connect at all. Isolated to this one helper so no other
/// client in the app is affected by it.
http.Client buildProxmoxHttpClient({required bool allowSelfSigned}) {
  if (!allowSelfSigned) return http.Client();
  final ioClient = HttpClient()
    ..badCertificateCallback = (cert, host, port) => true;
  return IOClient(ioClient);
}
