import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../server/data/larenor_server_api.dart';
import '../data/local_notification_controller.dart';
import '../data/local_notification_platform.dart';
import '../data/local_notification_store.dart';

final localNotificationApiFactoryProvider =
    Provider<LocalNotificationApiFactory>(
      (_) =>
          (endpoint) => LarenorServerApi(endpoint: endpoint),
    );
final localNotificationStoreProvider = Provider<LocalNotificationStore>(
  (_) => LocalNotificationStore(),
);
final localNotificationPermissionProvider =
    Provider<LocalNotificationPermissionGateway>(
      (_) => InAppNotificationPermissionGateway(),
    );
final localNotificationClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
final localNotificationPlatformProvider = Provider<LocalNotificationPlatform>(
  (_) => AndroidLocalNotificationPlatform(),
);
