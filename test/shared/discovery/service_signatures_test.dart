import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/shared/discovery/service_signatures.dart';

void main() {
  group('ServiceSignatures body-title matchers', () {
    test('sonarr matches a 200 response whose body mentions Sonarr', () {
      final response = http.Response('<html><title>Sonarr</title></html>', 200);
      expect(ServiceSignatures.sonarr.matches(response), isTrue);
    });

    test('sonarr does not match a different app\'s page', () {
      final response = http.Response('<html><title>Radarr</title></html>', 200);
      expect(ServiceSignatures.sonarr.matches(response), isFalse);
    });

    test('sonarr does not match a non-200 status even with the right body', () {
      final response = http.Response('Sonarr', 500);
      expect(ServiceSignatures.sonarr.matches(response), isFalse);
    });

    test('matching is case-insensitive', () {
      final response = http.Response('<TITLE>QBITTORRENT</TITLE>', 200);
      expect(ServiceSignatures.qbittorrent.matches(response), isTrue);
    });
  });

  group('ServiceSignatures.proxmox', () {
    test('matches Proxmox\'s unauthenticated version JSON shape', () {
      final response = http.Response(
        '{"data":{"version":"8.0.3","release":"8.0"}}',
        200,
      );
      expect(ServiceSignatures.proxmox.matches(response), isTrue);
    });

    test('does not match an unrelated JSON body', () {
      final response = http.Response('{"hello":"world"}', 200);
      expect(ServiceSignatures.proxmox.matches(response), isFalse);
    });

    test('probes over HTTPS with self-signed certs allowed', () {
      expect(ServiceSignatures.proxmox.useHttps, isTrue);
      expect(ServiceSignatures.proxmox.allowSelfSignedCert, isTrue);
      expect(ServiceSignatures.proxmox.path, '/api2/json/version');
    });
  });

  group('default ports', () {
    test('each signature probes its service\'s documented default port', () {
      expect(ServiceSignatures.jellyseerr.ports, [5055]);
      expect(ServiceSignatures.sonarr.ports, [8989]);
      expect(ServiceSignatures.radarr.ports, [7878]);
      expect(ServiceSignatures.lidarr.ports, [8686]);
      expect(ServiceSignatures.readarr.ports, [8787]);
      expect(ServiceSignatures.bazarr.ports, [6767]);
      expect(ServiceSignatures.prowlarr.ports, [9696]);
      expect(ServiceSignatures.qbittorrent.ports, containsAll([8080, 8090]));
      expect(ServiceSignatures.proxmox.ports, [8006]);
    });
  });
}
