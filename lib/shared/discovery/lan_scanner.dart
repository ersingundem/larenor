import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// A server found on the local subnet by [LanScanner].
class DiscoveredLanServer {
  const DiscoveredLanServer({required this.baseUrl});

  final String baseUrl;
}

/// How to recognize one particular service while sweeping the LAN — no
/// standard discovery protocol exists for most self-hosted services
/// (unlike Home Assistant's mDNS or Jellyfin's UDP broadcast), so this
/// probes each candidate host's likely port with a plain HTTP GET and
/// checks the response for something that identifies the app, without
/// needing credentials (discovery happens before the user has entered
/// any API key/password).
class LanServiceSignature {
  const LanServiceSignature({
    required this.ports,
    this.path = '/',
    this.useHttps = false,
    this.allowSelfSignedCert = false,
    required this.matches,
  });

  final List<int> ports;
  final String path;
  final bool useHttps;
  final bool allowSelfSignedCert;
  final bool Function(http.Response response) matches;

  /// Matches when the response body contains [needle] (case-insensitive)
  /// — covers the common case of a self-hosted app's web UI serving an
  /// HTML page with its own name in the `<title>`.
  factory LanServiceSignature.bodyContains(
    String needle, {
    required List<int> ports,
    String path = '/',
    bool useHttps = false,
    bool allowSelfSignedCert = false,
  }) {
    final lower = needle.toLowerCase();
    return LanServiceSignature(
      ports: ports,
      path: path,
      useHttps: useHttps,
      allowSelfSignedCert: allowSelfSignedCert,
      matches: (response) =>
          response.statusCode == 200 &&
          response.body.toLowerCase().contains(lower),
    );
  }
}

/// Sweeps the device's local /24 subnet for a service matching a given
/// [LanServiceSignature] — the generic fallback used by every integration
/// that doesn't have a real discovery protocol of its own (contrast with
/// `HaDiscoveryService` (mDNS) and Jellyfin's UDP broadcast client).
class LanScanner {
  static const _concurrency = 32;
  static const _timeout = Duration(milliseconds: 700);

  final _controller = StreamController<DiscoveredLanServer>.broadcast();
  bool _cancelled = false;

  Stream<DiscoveredLanServer> get servers => _controller.stream;

  Future<void> scan(LanServiceSignature signature) async {
    final subnet = await _localSubnetPrefix();
    if (subnet == null) {
      await _controller.close();
      return;
    }

    final hosts = List.generate(254, (i) => '$subnet.${i + 1}');
    var index = 0;

    Future<void> worker() async {
      final client = signature.allowSelfSignedCert
          ? IOClient(HttpClient()..badCertificateCallback = (_, _, _) => true)
          : http.Client();
      try {
        while (!_cancelled && index < hosts.length) {
          final host = hosts[index++];
          for (final port in signature.ports) {
            if (_cancelled) break;
            await _probe(client, host, port, signature);
          }
        }
      } finally {
        client.close();
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _probe(
    http.Client client,
    String host,
    int port,
    LanServiceSignature signature,
  ) async {
    final scheme = signature.useHttps ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port${signature.path}');
    try {
      final response = await client.get(uri).timeout(_timeout);
      if (signature.matches(response) && !_controller.isClosed) {
        _controller.add(DiscoveredLanServer(baseUrl: '$scheme://$host:$port'));
      }
    } catch (_) {
      // Most of the /24 won't have anything listening — timeouts and
      // connection refusals are the expected common case, not errors.
    }
  }

  Future<String?> _localSubnetPrefix() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip == null) return null;
      final parts = ip.split('.');
      if (parts.length != 4) return null;
      return '${parts[0]}.${parts[1]}.${parts[2]}';
    } on SocketException {
      return null;
    }
  }

  void cancel() {
    _cancelled = true;
  }
}
