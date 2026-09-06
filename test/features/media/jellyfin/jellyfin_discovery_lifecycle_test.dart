import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_discovery.dart';

class FakeJellyfinSocket implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>();
  int sends = 0, closes = 0;
  bool _broadcast = false;
  bool failSend = false;
  void Function()? enabling;
  Datagram? packet;
  int receives = 0;
  @override
  bool get broadcastEnabled => _broadcast;
  @override
  set broadcastEnabled(bool value) {
    _broadcast = value;
    enabling?.call();
  }

  @override
  Datagram? receive() {
    receives++;
    final result = packet;
    packet = null;
    return result;
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sends++;
    if (failSend) throw StateError('synthetic-send-error');
    expect(address.address, '255.255.255.255');
    expect(port, 7359);
    return buffer.length;
  }

  @override
  void close() {
    closes++;
    events.close();
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final reason in ['stopped', 'source_lost']) {
    test(
      'discovery $reason during pending bind closes socket without broadcast',
      () async {
        final socket = FakeJellyfinSocket(),
            bound = Completer<RawDatagramSocket>();
        var current = true;
        final service = JellyfinDiscoveryService(bind: () => bound.future);
        final pending = service.start(isCurrent: () => current);
        if (reason == 'stopped') {
          await service.stop();
        } else {
          current = false;
        }
        bound.complete(socket);
        await pending;
        expect(socket.sends, 0);
        expect(socket.closes, 1);
        await service.stop();
      },
    );
  }
  test('discovery denied before start never asks the socket factory', () async {
    var binds = 0;
    final socket = FakeJellyfinSocket();
    final service = JellyfinDiscoveryService(
      bind: () async {
        binds++;
        return socket;
      },
    );
    await service.start(isCurrent: () => false);
    expect(binds, 0);
    expect(socket.sends, 0);
    await service.stop();
  });
  test('current Direct discovery broadcasts once and closes on stop', () async {
    final socket = FakeJellyfinSocket();
    final service = JellyfinDiscoveryService(bind: () async => socket);
    await service.start(isCurrent: () => true);
    expect(socket.sends, 1);
    expect(socket.broadcastEnabled, isTrue);
    await service.stop();
    expect(socket.closes, 1);
  });
  test('reply stream accepts valid data and coalesces repeated IDs without real UDP', () async {
    final socket = FakeJellyfinSocket();
    final service = JellyfinDiscoveryService(bind: () async => socket);
    final replies = <List<DiscoveredJellyfinServer>>[];
    final sub = service.servers.listen(replies.add);
    await service.start();
    await service.start();
    expect(socket.sends, 1);
    socket.events.add(RawSocketEvent.write);
    await Future<void>.delayed(Duration.zero);
    expect(socket.receives, 0);
    for (final payload in [
      'invalid',
      '{"Address":"http://synthetic.invalid:8096","Id":"same","Name":"One"}',
      '{"Address":"http://synthetic.invalid:8096","Id":"same","Name":"Two"}',
    ]) {
      socket.packet = Datagram(
        utf8.encode(payload),
        InternetAddress.loopbackIPv4,
        7359,
      );
      socket.events.add(RawSocketEvent.read);
      await Future<void>.delayed(Duration.zero);
    }
    expect(replies.length, 2);
    expect(replies.last.single.name, 'Two');
    await service.stop();
    await service.stop();
    await sub.cancel();
    expect(socket.closes, 1);
  });
  test('source lost before send closes listener without broadcast', () async {
    var current = true;
    final socket = FakeJellyfinSocket()..enabling = () => current = false;
    final service = JellyfinDiscoveryService(bind: () async => socket);
    await service.start(isCurrent: () => current);
    expect(socket.sends, 0);
    expect(socket.closes, 1);
  });
  test(
    'late event after source retirement closes without receiving private data',
    () async {
      var current = true;
      final socket = FakeJellyfinSocket();
      final service = JellyfinDiscoveryService(bind: () async => socket);
      final replies = <List<DiscoveredJellyfinServer>>[];
      final sub = service.servers.listen(replies.add);
      await service.start(isCurrent: () => current);
      current = false;
      socket.events.add(RawSocketEvent.read);
      await Future<void>.delayed(Duration.zero);
      expect(socket.receives, 0);
      expect(replies, isEmpty);
      expect(socket.closes, 1);
      await service.stop();
      await sub.cancel();
    },
  );
  test('throwing permission callback never binds', () async {
    var binds = 0;
    final service = JellyfinDiscoveryService(
      bind: () async {
        binds++;
        return FakeJellyfinSocket();
      },
    );
    await service.start(isCurrent: () => throw StateError('private'));
    expect(binds, 0);
    await service.stop();
  });
  test(
    'failed send closes socket and preserves failure without retry',
    () async {
      final socket = FakeJellyfinSocket()..failSend = true;
      final service = JellyfinDiscoveryService(bind: () async => socket);
      await expectLater(service.start(), throwsStateError);
      expect(socket.sends, 1);
      expect(socket.closes, 1);
      await service.start();
      expect(socket.sends, 1);
      await service.stop();
    },
  );
  test('bind failure is reported and explicit stop is safe', () async {
    final service = JellyfinDiscoveryService(
      bind: () async => throw StateError('synthetic-bind'),
    );
    await expectLater(service.start(), throwsStateError);
    await service.stop();
  });
}
