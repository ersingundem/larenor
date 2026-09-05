import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/providers/settings_providers.dart';
import '../data/kiosk_api.dart';
import '../data/kiosk_controller.dart';

final kioskApiProvider = Provider<KioskApi>((ref) => AndroidKioskApi());
final kioskControllerProvider = Provider.autoDispose<KioskController>((ref) {
  final controller = KioskController(
    ref.watch(kioskApiProvider),
    ref.watch(pinLockStoreProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
