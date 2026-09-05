import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_data_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';

final homeLayoutClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// Fresh account authority; the retained runtime identity is not an access grant.
HomeLayoutAccess? homeLayoutAccess(
  HomeSessionController? home, {
  DateTime Function()? clock,
}) {
  if (home == null ||
      home.source != HomeSource.verifiedCore ||
      home.busy ||
      home.failure != null ||
      !home.interaction.active)
    return null;
  final account = home.account;
  final session = account.session;
  final context = session?.context;
  final now = clock ?? DateTime.now;
  if (!account.initialized ||
      account.working ||
      account.hasPendingContext ||
      session == null ||
      context == null ||
      session.authMutationPending ||
      session.user.mustChangePassword ||
      session.expiresSoon(now()))
    return null;
  return HomeLayoutAccess._(
    home,
    session,
    account.generation,
    home.interaction.epoch,
    now,
    HomeDataScope.fromJson({
      'coreId': context.coreId,
      'homeId': context.homeId,
      'userId': session.user.id,
    }),
  );
}

final class HomeLayoutAccess {
  HomeLayoutAccess._(
    this._home,
    this._session,
    this._generation,
    this._epoch,
    this._clock,
    this.scope,
  );
  final HomeSessionController _home;
  final ServerSession _session;
  final int _generation, _epoch;
  final DateTime Function() _clock;
  final HomeDataScope scope;

  bool get isCurrent =>
      _home.source == HomeSource.verifiedCore &&
      !_home.busy &&
      _home.failure == null &&
      _home.interaction.active &&
      _home.interaction.epoch == _epoch &&
      _home.account.generation == _generation &&
      identical(_home.account.session, _session) &&
      !_home.account.working &&
      !_home.account.hasPendingContext &&
      !_session.expiresSoon(_clock());

  DateTime get validUntil =>
      _session.expiresAt.subtract(const Duration(seconds: 30));
}
