import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/hub/presentation/media_session_state.dart';
import '../data/admin_client.dart';
import '../providers/admin_providers.dart';

/// Binds an administrator route to the exact HA client, app interaction and
/// lifecycle that opened it. Returning to the foreground never revives a
/// callback captured before authority was lost.
abstract class AdminSessionState<T extends ConsumerStatefulWidget>
    extends MediaSessionState<T> {
  late final HaAdminClient? adminClient;
  late final int _sessionAnchor;
  bool _adminExpired = false;
  bool _wasVisible = true;
  int adminActionGeneration = 0;

  @override
  void initState() {
    super.initState();
    adminClient = ref.read(haAdminClientProvider);
    _sessionAnchor = sessionGeneration;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (_wasVisible && !visible) adminActionGeneration++;
    _wasVisible = visible;
  }

  void watchAdminSession() {
    ref.watch(haAdminClientProvider);
    ref.listen(haAdminClientProvider, (_, next) {
      if (!_adminExpired && !identical(adminClient, next)) {
        setState(() {
          _adminExpired = true;
          adminActionGeneration++;
          adminSessionExpired();
        });
      }
    });
  }

  bool get adminAuthorityCurrent =>
      sessionCurrent(_sessionAnchor) &&
      !_adminExpired &&
      adminClient != null &&
      identical(adminClient, ref.read(haAdminClientProvider));

  bool adminActionCurrent(int generation) =>
      adminAuthorityCurrent &&
      generation == adminActionGeneration &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  @override
  void clearPendingInteraction() {
    _adminExpired = true;
    adminActionGeneration++;
    adminSessionExpired();
  }

  void adminSessionExpired() {}
}
