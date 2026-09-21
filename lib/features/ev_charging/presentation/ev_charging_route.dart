import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_page_scaffold.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/ev_charging_api.dart';
import '../data/ev_charging_controller.dart';
import 'ev_charging_screen.dart';

final class EvChargingRoute extends ConsumerStatefulWidget {
  const EvChargingRoute({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<EvChargingRoute> createState() => _EvChargingRouteState();
}

final class _EvChargingRouteState extends ConsumerState<EvChargingRoute>
    with WidgetsBindingObserver {
  ServerAccountController? account;
  EvChargingController? controller;
  Object? session;
  int? generation;
  bool foreground = true, closed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool authority() {
    if (!mounted || closed || !foreground) return false;
    try {
      final value = account, currentSession = value?.session;
      return value != null &&
          identical(ref.read(serverAccountControllerProvider), value) &&
          value.isCurrent(generation!) &&
          identical(currentSession, session) &&
          value.initialized &&
          !value.working &&
          currentSession?.context != null &&
          widget.gateCurrent() &&
          TickerMode.valuesOf(context).enabled &&
          (ModalRoute.of(context)?.isCurrent ?? true);
    } catch (_) {
      return false;
    }
  }

  String id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void changed() {
    if (!mounted || authority()) return;
    closed = true;
    controller?.retire();
    controller = null;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final value = ref.read(serverAccountControllerProvider);
    if (account == null) {
      account = value;
      generation = value.generation;
      session = value.session;
      value.addListener(changed);
    } else if (!identical(account, value)) {
      closed = true;
      controller?.retire();
      controller = null;
    }
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      controller?.retire();
      controller = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    account?.removeListener(changed);
    controller?.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final strings = Localizations.localeOf(context).languageCode == 'tr'
        ? EvChargingStrings.tr
        : EvChargingStrings.en;
    if (controller == null && authority()) {
      controller = EvChargingController(
        gateway: AccountEvChargingGateway(
          account: account!,
          isCurrent: authority,
        ),
        isCurrent: authority,
        id: id,
        now: () => DateTime.now().toUtc(),
      );
    }
    final value = controller;
    if (value != null && authority()) {
      return EvChargingScreen(controller: value, strings: strings);
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(child: Center(child: Text(strings.unavailable))),
    );
  }
}
