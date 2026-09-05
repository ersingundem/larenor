import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';

// A separate transport owner lets this page retire reads without closing auth.
final homeResourcesApiFactoryProvider = Provider<ServerApiFactory>(
  (_) => (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final homeResourcesClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
