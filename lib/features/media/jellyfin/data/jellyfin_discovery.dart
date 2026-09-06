import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredJellyfinServer {
  const DiscoveredJellyfinServer({required this.name, required this.baseUrl});

  final String name;
  final String baseUrl;
}

/// Discovers Jellyfin servers on the local network via Jellyfin's own UDP
/// broadcast protocol: broadcast the literal message "Who is
/// JellyfinServer?" on port 7359, servers reply with
/// `{"Address": "http://host:port", "Id": "...", "Name": "..."}` —
/// see https://jellyfin.org/docs/general/networking/#udp-based-discovery.
class JellyfinDiscoveryService {
  JellyfinDiscoveryService({Future<RawDatagramSocket> Function()? bind})
    : _bind = bind ?? (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));
  final Future<RawDatagramSocket> Function() _bind;
  static const _port = 7359;
  static const _probeMessage = 'Who is JellyfinServer?';

  RawDatagramSocket? _socket;
  final _servers = <String, DiscoveredJellyfinServer>{};
  final _controller =
      StreamController<List<DiscoveredJellyfinServer>>.broadcast();

  Stream<List<DiscoveredJellyfinServer>> get servers => _controller.stream;

  Future<void> start({bool Function()? isCurrent}) async {
    final socket = await _bind();
    _socket = socket;
    socket.broadcastEnabled = true;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _onResponse(datagram.data);
    });

    socket.send(
      utf8.encode(_probeMessage),
      InternetAddress('255.255.255.255'),
      _port,
    );
  }

  void _onResponse(List<int> data) {
    final parsed = parseJellyfinDiscoveryResponse(data);
    if (parsed == null) return;
    _servers[parsed.id] = parsed.server;
    _controller.add(_servers.values.toList());
  }

  Future<void> stop() async {
    _socket?.close();
    await _controller.close();
  }
}

/// A parsed discovery reply, keyed by the server's `Id` so repeated
/// broadcasts from the same server replace rather than duplicate it.
class ParsedJellyfinDiscoveryResponse {
  const ParsedJellyfinDiscoveryResponse({
    required this.id,
    required this.server,
  });

  final String id;
  final DiscoveredJellyfinServer server;
}

/// Pulled out of [JellyfinDiscoveryService] so the response parsing is
/// unit-testable without standing up a real UDP socket.
ParsedJellyfinDiscoveryResponse? parseJellyfinDiscoveryResponse(
  List<int> data,
) {
  try {
    final decoded = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    final address = decoded['Address'] as String?;
    final id = decoded['Id'] as String?;
    final name = decoded['Name'] as String?;
    if (address == null || id == null) return null;
    return ParsedJellyfinDiscoveryResponse(
      id: id,
      server: DiscoveredJellyfinServer(name: name ?? address, baseUrl: address),
    );
  } catch (_) {
    // Not a well-formed Jellyfin discovery reply.
    return null;
  }
}
