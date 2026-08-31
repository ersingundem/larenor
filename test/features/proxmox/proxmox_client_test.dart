import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/proxmox_api_exception.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';

void main() {
  const config = ProxmoxConfig(
    host: 'proxmox.local',
    port: 8006,
    username: 'root',
    realm: 'pam',
    password: 'secret',
    allowSelfSigned: true,
  );

  http.Response okData(dynamic data) =>
      http.Response(jsonEncode({'data': data}), 200);

  Future<ProxmoxClient> loggedInClient(
    Future<http.Response> Function(http.Request) handler,
  ) async {
    var loggedIn = false;
    final client = ProxmoxClient(
      config: config,
      httpClient: MockClient((request) async {
        if (!loggedIn && request.url.path.endsWith('/access/ticket')) {
          loggedIn = true;
          return okData({'ticket': 'tkt123', 'CSRFPreventionToken': 'csrf123'});
        }
        return handler(request);
      }),
    );
    await client.login();
    return client;
  }

  group('login', () {
    test(
      'posts username@realm + password and stores the ticket/CSRF',
      () async {
        final client = ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/api2/json/access/ticket');
            expect(request.bodyFields['username'], 'root@pam');
            expect(request.bodyFields['password'], 'secret');
            return okData({
              'ticket': 'tkt123',
              'CSRFPreventionToken': 'csrf123',
            });
          }),
        );

        await client.login();

        // A mutating call should now carry both the cookie and CSRF header.
        final mutatingClient = ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/access/ticket')) {
              return okData({
                'ticket': 'tkt123',
                'CSRFPreventionToken': 'csrf123',
              });
            }
            expect(request.headers['Cookie'], 'PVEAuthCookie=tkt123');
            expect(request.headers['CSRFPreventionToken'], 'csrf123');
            return okData('UPID:pve1:...');
          }),
        );
        await mutatingClient.login();
        await mutatingClient.powerAction(
          'pve1',
          ProxmoxGuestType.qemu,
          100,
          'start',
        );
      },
    );

    test('throws on a non-200 response', () async {
      final client = ProxmoxClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      expect(client.login(), throwsA(isA<ProxmoxApiException>()));
    });

    test('throws when the response is missing ticket/CSRF fields', () async {
      final client = ProxmoxClient(
        config: config,
        httpClient: MockClient((request) async => okData({})),
      );
      expect(client.login(), throwsA(isA<ProxmoxApiException>()));
    });
  });

  group('getNodes', () {
    test('unwraps the data envelope into a list of nodes', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/api2/json/nodes');
        return okData([
          {'node': 'pve1', 'status': 'online'},
        ]);
      });

      final nodes = await client.getNodes();
      expect(nodes.single.name, 'pve1');
    });
  });

  group('getGuests', () {
    test('merges qemu and lxc lists, tagging each with its type', () async {
      final client = await loggedInClient((request) async {
        if (request.url.path.endsWith('/qemu')) {
          return okData([
            {'vmid': 100, 'name': 'vm1', 'status': 'running'},
          ]);
        }
        if (request.url.path.endsWith('/lxc')) {
          return okData([
            {'vmid': 200, 'name': 'ct1', 'status': 'stopped'},
          ]);
        }
        throw StateError('unexpected path ${request.url.path}');
      });

      final guests = await client.getGuests('pve1');
      expect(guests, hasLength(2));
      expect(
        guests.map((g) => g.type),
        containsAll([ProxmoxGuestType.qemu, ProxmoxGuestType.lxc]),
      );
    });
  });

  group('cloneGuest', () {
    test('posts newid/full/name/storage and returns the UPID', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/api2/json/nodes/pve1/qemu/100/clone');
        expect(request.bodyFields['newid'], '101');
        expect(request.bodyFields['full'], '1');
        expect(request.bodyFields['name'], 'clone-1');
        expect(request.bodyFields['storage'], 'local-lvm');
        return okData('UPID:pve1:clone');
      });

      final upid = await client.cloneGuest(
        'pve1',
        ProxmoxGuestType.qemu,
        100,
        newId: 101,
        name: 'clone-1',
        targetStorage: 'local-lvm',
      );
      expect(upid, 'UPID:pve1:clone');
    });
  });

  group('getTaskStatus', () {
    test('reports running when status is "running"', () async {
      final client = await loggedInClient(
        (request) async => okData({'status': 'running'}),
      );
      final poll = await client.getTaskStatus('pve1', 'UPID:pve1:x');
      expect(poll.isRunning, isTrue);
      expect(poll.isSuccess, isFalse);
    });

    test('reports success when stopped with exitstatus OK', () async {
      final client = await loggedInClient(
        (request) async => okData({'status': 'stopped', 'exitstatus': 'OK'}),
      );
      final poll = await client.getTaskStatus('pve1', 'UPID:pve1:x');
      expect(poll.isRunning, isFalse);
      expect(poll.isSuccess, isTrue);
    });
  });

  group('vncTicket / termTicket / consoleWebSocketUrl', () {
    test(
      'vncTicket parses ticket + port from the qemu vncproxy endpoint',
      () async {
        final client = await loggedInClient((request) async {
          expect(request.url.path, '/api2/json/nodes/pve1/qemu/100/vncproxy');
          return okData({'ticket': 'vnc-ticket', 'port': 5900});
        });

        final ticket = await client.vncTicket('pve1', 100);
        expect(ticket.ticket, 'vnc-ticket');
        expect(ticket.port, 5900);
      },
    );

    test('termTicket hits the lxc termproxy endpoint', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/api2/json/nodes/pve1/lxc/200/termproxy');
        return okData({'ticket': 'term-ticket', 'port': 5901});
      });

      final ticket = await client.termTicket('pve1', 200);
      expect(ticket.ticket, 'term-ticket');
      expect(ticket.port, 5901);
    });

    test(
      'the websocket URL connects to the API port, not the console port',
      () async {
        final client = await loggedInClient((_) async => okData(null));
        final url = client.consoleWebSocketUrl(
          node: 'pve1',
          console: const ProxmoxConsoleTicket(ticket: 'tkt', port: 5900),
        );

        final uri = Uri.parse(url);
        expect(uri.scheme, 'wss');
        expect(uri.host, 'proxmox.local');
        expect(uri.port, 8006);
        expect(uri.path, '/api2/json/nodes/pve1/vncwebsocket');
        expect(uri.queryParameters['port'], '5900');
        expect(uri.queryParameters['vncticket'], 'tkt');
      },
    );
  });
}
