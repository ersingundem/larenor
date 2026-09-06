import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../health/data/integration_health.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../providers/keenetic_providers.dart';

/// Route-local authority for existing Keenetic readers and commands.
/// This never acquires credentials, constructs a client, or sends a request.
abstract class KeeneticSessionState<T extends ConsumerStatefulWidget>
    extends MediaSessionState<T> {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  Route<dynamic>? ownedModal;
  bool _visible = true;

  void watchKeeneticSession() {
    ref.watch(directHomeAccessProvider);
    watchMediaAccount(IntegrationId.keenetic, keeneticConnectionProvider);
  }

  bool get keeneticAvailable {
    if (!mounted ||
        sessionExpired ||
        !_access.isCurrent ||
        !identical(_access, ref.read(directHomeAccessProvider))) {
      return false;
    }
    final reading = ref.read(keeneticConnectionProvider);
    return !reading.isLoading && !reading.hasError && reading.value != null;
  }

  bool get _viewCurrent =>
      TickerMode.valuesOf(context).enabled &&
      ((ModalRoute.of(context)?.isCurrent ?? true) ||
          ownedModal?.isCurrent == true);

  bool keeneticCurrent(int generation) =>
      sessionCurrent(generation) && keeneticAvailable && _viewCurrent;

  /// A detail route may outlive the parent route's visibility, but never the
  /// exact confirmed account that supplied its immutable device observation.
  bool Function()? captureKeeneticSource() {
    if (!keeneticAvailable) return null;
    final value = ref.read(keeneticConnectionProvider).value;
    return () =>
        keeneticAvailable &&
        identical(value, ref.read(keeneticConnectionProvider).value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = _viewCurrent;
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  @override
  void clearPendingInteraction() {
    final route = ownedModal;
    ownedModal = null;
    // Authority is already retired. Removing a covered route during another
    // route's build would mutate Navigator's animation listeners mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }

  @override
  void dispose() {
    clearPendingInteraction();
    super.dispose();
  }
}
