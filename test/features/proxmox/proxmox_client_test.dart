import 'dart:async';
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
          expect(request.url.queryParameters['full'], '1');
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
          type: ProxmoxGuestType.qemu,
          vmid: 100,
          console: const ProxmoxConsoleTicket(ticket: 'tkt', port: 5900),
        );

        final uri = Uri.parse(url);
        expect(uri.scheme, 'wss');
        expect(uri.host, 'proxmox.local');
        expect(uri.port, 8006);
        expect(uri.path, '/api2/json/nodes/pve1/qemu/100/vncwebsocket');
        expect(uri.queryParameters['port'], '5900');
        expect(uri.queryParameters['vncticket'], 'tkt');
      },
    );
  });
  group('session recovery', () {
    test('concurrent requests share the first login', () async {
      var logins = 0;
      final gate = Completer<void>();
      final client = ProxmoxClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/access/ticket')) {
            logins++;
            await gate.future;
            return okData({'ticket': 'ticket', 'CSRFPreventionToken': 'csrf'});
          }
          return okData([]);
        }),
      );
      final calls = Future.wait([client.getNodes(), client.getNodes()]);
      gate.complete();
      await calls;
      expect(logins, 1);
    });

    test('renews before the two-hour ticket expires', () async {
      var now = DateTime(2026, 1, 1);
      var logins = 0;
      final client = ProxmoxClient(
        config: config,
        now: () => now,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/access/ticket')) {
            logins++;
            return okData({
              'ticket': 'ticket$logins',
              'CSRFPreventionToken': 'csrf$logins',
            });
          }
          expect(request.headers['Cookie'], 'PVEAuthCookie=ticket$logins');
          return okData([]);
        }),
      );
      await client.getNodes();
      now = now.add(const Duration(minutes: 109));
      await client.getNodes();
      expect(logins, 1);
      now = now.add(const Duration(minutes: 1));
      await client.getNodes();
      expect(logins, 2);
    });

    test(
      'retries a rejected mutation once with fresh cookie and CSRF',
      () async {
        var logins = 0;
        var writes = 0;
        final client = ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/access/ticket')) {
              logins++;
              return okData({
                'ticket': 'ticket$logins',
                'CSRFPreventionToken': 'csrf$logins',
              });
            }
            writes++;
            expect(request.headers['Cookie'], 'PVEAuthCookie=ticket$logins');
            expect(request.headers['CSRFPreventionToken'], 'csrf$logins');
            return writes == 1
                ? http.Response('', 401)
                : okData('UPID:pve1:start');
          }),
        );
        expect(
          await client.powerAction('pve1', ProxmoxGuestType.qemu, 100, 'start'),
          'UPID:pve1:start',
        );
        expect(logins, 2);
        expect(writes, 2);
      },
    );

    test(
      'permission errors do not retry or hide API validation details',
      () async {
        var writes = 0;
        final client = await loggedInClient((request) async {
          writes++;
          return http.Response(
            jsonEncode({
              'errors': {'storage': 'permission denied'},
            }),
            403,
          );
        });
        await expectLater(
          client.powerAction('pve1', ProxmoxGuestType.qemu, 100, 'start'),
          throwsA(
            isA<ProxmoxApiException>().having(
              (error) => error.message,
              'message',
              contains('storage: permission denied'),
            ),
          ),
        );
        expect(writes, 1);
      },
    );
  });

  test(
    'container clones use hostname and omit storage for a linked clone',
    () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/api2/json/nodes/pve1/lxc/100/clone');
        expect(request.bodyFields['hostname'], 'new-container');
        expect(request.bodyFields.containsKey('name'), isFalse);
        expect(request.bodyFields.containsKey('storage'), isFalse);
        expect(request.bodyFields['full'], '0');
        return okData('UPID:pve1:clone');
      });
      await client.cloneGuest(
        'pve1',
        ProxmoxGuestType.lxc,
        100,
        newId: 101,
        name: 'new-container',
        targetStorage: 'local',
        full: false,
      );
    },
  );

  test('next guest ID comes from the whole cluster', () async {
    final client = await loggedInClient((request) async {
      expect(request.url.path, '/api2/json/cluster/nextid');
      return okData('105');
    });
    expect(await client.getNextGuestId(), 105);
  });

  test('task polling propagates a stopped task failure', () async {
    var polls = 0;
    final client = await loggedInClient((request) async {
      polls++;
      return okData(
        polls == 1
            ? {'status': 'running'}
            : {'status': 'stopped', 'exitstatus': 'storage is full'},
      );
    });
    await expectLater(
      client.waitForTask('pve1', 'UPID:pve1:test', interval: Duration.zero),
      throwsA(
        isA<ProxmoxApiException>().having(
          (error) => error.message,
          'message',
          'storage is full',
        ),
      ),
    );
    expect(polls, 2);
  });

  test('task polling stops without more requests when screen closes', () async {
    var visible = true;
    var polls = 0;
    final client = await loggedInClient((request) async {
      polls++;
      visible = false;
      return okData({'status': 'running'});
    });
    expect(
      await client.waitForTask(
        'pve1',
        'UPID:pve1:test',
        shouldContinue: () => visible,
        interval: Duration.zero,
      ),
      isNull,
    );
    expect(polls, 1);
  });

  test('task logs decode output and encode the UPID as one segment', () async {
    final client = await loggedInClient((request) async {
      expect(request.url.pathSegments.last, 'log');
      expect(request.url.pathSegments[5], 'UPID:pve1:task/a');
      expect(request.url.queryParameters['limit'], '500');
      return okData([
        {'n': 1, 't': 'Started'},
        {'n': 2, 't': 'TASK OK'},
      ]);
    });
    expect(await client.getTaskLog('pve1', 'UPID:pve1:task/a'), [
      'Started',
      'TASK OK',
    ]);
  });

  test('console pages choose native VM and container clients without URL credentials', () async {
    final client = await loggedInClient((request) async => okData(null));
    for (final type in ProxmoxGuestType.values) {
      final uri = client.consolePageUrl(
        ProxmoxGuest(
          type: type,
          node: 'pve1',
          vmid: 100,
          name: 'Guest',
          status: 'running',
        ),
      );
      expect(uri.host, config.host);
      expect(uri.port, 8006);
      expect(
        uri.queryParameters['console'],
        type == ProxmoxGuestType.qemu ? 'kvm' : 'lxc',
      );
      expect(
        uri.queryParameters[type == ProxmoxGuestType.qemu
            ? 'novnc'
            : 'xtermjs'],
        '1',
      );
      expect(uri.queryParameters['vmid'], '100');
      expect(uri.toString(), isNot(contains('secret')));
      expect(uri.toString(), isNot(contains('tkt123')));
    }
  });
}
