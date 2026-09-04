import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/rest_client.dart';
import '../../ha_client/data/ws_client.dart';

abstract interface class TodayApi {
  Future<Map<String, dynamic>> getConfig();
  Future<List<HaEntity>> getEntities();
  Future<List<Map<String, dynamic>>> getCalendars();
  Future<List<Map<String, dynamic>>> getCalendarEvents(
    String entityId,
    DateTime start,
    DateTime end,
  );
  Future<Object?> getTodoItems(String entityId);
  Future<Object?> getNotifications();
  Future<TodaySubscription> subscribeNotifications();
  Future<void> callService(
    String domain,
    String service,
    Map<String, dynamic> data, {
    String? entityId,
  });
}

class TodaySubscription {
  const TodaySubscription(this.events, this.cancel);
  final Stream<dynamic> events;
  final Future<void> Function() cancel;
}

/// HA 2026.8.3 contracts verified in components/todo, calendar and
/// persistent_notification. These existing clients enforce server boundaries.
class HaTodayApi implements TodayApi {
  HaTodayApi({required this.rest, required this.ws, this.entities});
  final HaRestClient rest;
  final HaWebSocketClient ws;
  final Future<List<HaEntity>> Function()? entities;
  @override
  Future<Map<String, dynamic>> getConfig() => rest.getConfig();
  @override
  Future<List<HaEntity>> getEntities() => entities?.call() ?? rest.getStates();
  @override
  Future<List<Map<String, dynamic>>> getCalendars() => rest.getCalendars();
  @override
  Future<List<Map<String, dynamic>>> getCalendarEvents(
    String entityId,
    DateTime start,
    DateTime end,
  ) => rest.getCalendarEvents(entityId, start: start, end: end);
  @override
  Future<Object?> getTodoItems(String entityId) =>
      ws.sendCommand({'type': 'todo/item/list', 'entity_id': entityId});
  @override
  Future<Object?> getNotifications() =>
      ws.sendCommand({'type': 'persistent_notification/get'});
  @override
  Future<TodaySubscription> subscribeNotifications() async {
    final subscription = await ws.subscribeCommand({
      'type': 'persistent_notification/subscribe',
    });
    return TodaySubscription(subscription.events, subscription.cancel);
  }

  @override
  Future<void> callService(
    String domain,
    String service,
    Map<String, dynamic> data, {
    String? entityId,
  }) =>
      rest.callService(domain, service, entityId: entityId, serviceData: data);
}
