import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';

// A separate transport owner lets this page retire reads without closing auth.
final homeResourcesApiFactoryProvider = Provider<ServerApiFactory>(
  (_) =>
      (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final homeResourcesClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

final class HomeResourcesApi {
  const HomeResourcesApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;

  Future<HomeResourcePage> list({
    String? after,
    String? snapshot,
    int limit = HomeResourcePage.pageSize,
  }) async {
    final result = await api.request(
      'GET',
      '/home-resources/${context.coreId}/${context.homeId}',
      token: token,
      queryParameters: {
        'limit': '$limit',
        if (after != null) 'after': after,
        if (snapshot != null) 'expectedSnapshot': snapshot,
      },
    );
    return HomeResourcePage.fromJson(
      result,
      expectedContext: context,
      after: after,
      expectedSnapshot: snapshot,
      limit: limit,
    );
  }
}
