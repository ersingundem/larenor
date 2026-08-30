import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

class DiscoveredHaServer {
  const DiscoveredHaServer({required this.name, required this.baseUrl});

  final String name;
  final String baseUrl;
}

/// Discovers Home Assistant instances on the local network via mDNS/Zeroconf.
///
/// Home Assistant's `zeroconf` integration advertises itself as
/// `_home-assistant._tcp.local` with a `base_url` TXT record — see
/// https://www.home-assistant.io/integrations/zeroconf/
class HaDiscoveryService {
  static const _serviceType = '_home-assistant._tcp';

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  final _servers = <String, DiscoveredHaServer>{};
  final _controller = StreamController<List<DiscoveredHaServer>>.broadcast();

  Stream<List<DiscoveredHaServer>> get servers => _controller.stream;

  Future<void> start() async {
    final discovery = BonsoirDiscovery(type: _serviceType);
    _discovery = discovery;
    await discovery.initialize();

    _subscription = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          event.service.resolve(discovery.serviceResolver);
        case BonsoirDiscoveryServiceResolvedEvent():
          _onResolved(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          _servers.remove(event.service.name);
          _controller.add(_servers.values.toList());
        default:
          break;
      }
    });

    await discovery.start();
  }

  void _onResolved(BonsoirService? service) {
    if (service == null) return;

    final baseUrl =
        service.attributes['base_url'] ??
        (service.hostAddress != null
            ? 'http://${service.hostAddress}:${service.port}'
            : null);
    if (baseUrl == null) return;

    final name = service.attributes['location_name'] ?? service.name;
    _servers[service.name] = DiscoveredHaServer(name: name, baseUrl: baseUrl);
    _controller.add(_servers.values.toList());
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _discovery?.stop();
    await _controller.close();
  }
}
