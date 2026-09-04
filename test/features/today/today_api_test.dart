import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/today/data/today_api.dart';
import 'package:larenor/features/today/data/today_timezone.dart';

import '../ha_client/fake_socket.dart';
import 'fake_today_api.dart';

void main() {
  test('HA 2026.8.3 wire contracts: todo list, notifications get and subscribe ACK/event', () async {
    final socket = FakeSocket();
    final ws = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      channelFactory: (_) => socket,
    )..connect();
    final rest = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    addTearDown(ws.dispose);
    addTearDown(rest.dispose);
    await socket.authenticate();
    final api = HaTodayApi(rest: rest, ws: ws);
    final todos = api.getTodoItems('todo.shopping');
    await flushEvents();
    expect(socket.sent.last['type'], 'todo/item/list');
    expect(socket.sent.last['entity_id'], 'todo.shopping');
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
      'result': {
        'items': [todoItem()],
      },
    });
    expect((await todos as Map)['items'], hasLength(1));
    final notifications = api.getNotifications();
    await flushEvents();
    expect(socket.sent.last['type'], 'persistent_notification/get');
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
      'result': [notification()],
    });
    expect(await notifications, isA<List>());
    final pending = api.subscribeNotifications();
    await flushEvents();
    expect(socket.sent.last['type'], 'persistent_notification/subscribe');
    final id = socket.sent.last['id'];
    socket.emit({'type': 'result', 'id': id, 'success': true, 'result': null});
    socket.emit({
      'type': 'event',
      'id': id,
      'event': {
        'type': 'current',
        'notifications': {'notice': notification()},
      },
    });
    final subscription = await pending;
    final events = <dynamic>[];
    final listener = subscription.events.listen(events.add);
    await flushEvents();
    expect(events.single['type'], 'current');
    expect(
      events.single['notifications']['notice']['notification_id'],
      'notice',
    );
    final cancelled = subscription.cancel();
    await flushEvents();
    expect(socket.sent.last['type'], 'unsubscribe_events');
    expect(socket.sent.last['subscription'], id);
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
      'result': true,
    });
    await cancelled;
    await listener.cancel();
  });

  test('calendar GET uses bounded UTC range and mutations use explicit service body', () async {
    final requests = <http.Request>[];
    final rest = HaRestClient(
      baseUrl: 'http://ha.test/proxy',
      token: 'fixture',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('[]', 200);
      }),
    );
    final ws = HaWebSocketClient(
      baseUrl: 'http://ha.test/proxy',
      token: 'fixture',
      channelFactory: (_) => FakeSocket(),
    );
    addTearDown(rest.dispose);
    addTearDown(ws.dispose);
    final api = HaTodayApi(rest: rest, ws: ws);
    final day = TodayTimeZone('Europe/Berlin')
        .dayRange(DateTime.utc(2026, 3, 29, 12));
    await api.getCalendarEvents('calendar.family', day.start, day.end);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/proxy/api/calendars/calendar.family');
    expect(requests.single.url.queryParameters, {
      'start': '2026-03-28T23:00:00.000Z',
      'end': '2026-03-29T22:00:00.000Z',
    });
    await api.callService('todo', 'update_item', {
      'item': 'uid-one',
      'status': 'completed',
    }, entityId: 'todo.shopping');
    expect(requests.last.method, 'POST');
    expect(requests.last.url.path, '/proxy/api/services/todo/update_item');
    expect(jsonDecode(requests.last.body), {
      'entity_id': 'todo.shopping',
      'item': 'uid-one',
      'status': 'completed',
    });
  });
}
