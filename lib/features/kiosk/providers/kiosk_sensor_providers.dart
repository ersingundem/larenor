import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/kiosk_sensor_api.dart';
import '../data/kiosk_sensor_controller.dart';

final kioskSensorApiProvider = Provider<KioskSensorApi>(
  (ref) => AndroidKioskSensorApi(),
);

final kioskSensorControllerProvider =
    Provider.autoDispose<KioskSensorController>((ref) {
      final controller = KioskSensorController(
        ref.watch(kioskSensorApiProvider),
      );
      ref.onDispose(controller.retire);
      return controller;
    });
