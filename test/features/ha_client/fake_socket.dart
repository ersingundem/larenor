import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory wire protocol fixture; no network or Home Assistant required.
class FakeSocket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  bool failWrites = false;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  Future<void> get ready async {}

  @override
  late final WebSocketSink sink = _FakeSink(this);

  void emit(Map<String, dynamic> message) => incoming.add(jsonEncode(message));

  Future<void> authenticate({bool acknowledgeSubscription = true}) async {
    emit({'type': 'auth_required'});
    await flushEvents();
    emit({'type': 'auth_ok'});
    await flushEvents();
    if (acknowledgeSubscription) {
      emit({
        'type': 'result',
        'id': sent.last['id'],
        'success': true,
        'result': null,
      });
      await flushEvents();
    }
  }

  void change(String id, String state, {String? updated}) => emit({
    'id': sent.firstWhere(
      (command) => command['type'] == 'subscribe_events',
    )['id'],
    'type': 'event',
    'event': {
      'event_type': 'state_changed',
      'data': {
        'entity_id': id,
        'new_state': {
          'entity_id': id,
          'state': state,
          'last_updated': ?updated,
        },
      },
    },
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.socket);
  final FakeSocket socket;

  @override
  void add(dynamic data) {
    if (socket.failWrites) throw StateError('Socket closed');
    socket.sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    socket.closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);
