import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_page_scaffold.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/workshop_api.dart';
import '../data/workshop_controller.dart';
import 'workshop_screen.dart';

/// Owns one exact authenticated account/home and one visible route lifetime.
/// Losing any part of that authority retires pending reads and mutations.
final class WorkshopRoute extends ConsumerStatefulWidget {
  const WorkshopRoute({super.key, required this.gateCurrent});

  final bool Function() gateCurrent;

  @override
  ConsumerState<WorkshopRoute> createState() => _WorkshopRouteState();
}

final class _WorkshopRouteState extends ConsumerState<WorkshopRoute>
    with WidgetsBindingObserver {
  ServerAccountController? _account;
  WorkshopController? _controller;
  Object? _sessionIdentity;
  int? _generation;
  bool _foreground = true, _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  bool _authority() {
    if (!mounted || _closed || !_foreground) return false;
    try {
      final account = _account, session = account?.session;
      return account != null &&
          identical(ref.read(serverAccountControllerProvider), account) &&
          account.isCurrent(_generation!) &&
          identical(session, _sessionIdentity) &&
          account.initialized &&
          !account.working &&
          session?.context != null &&
          session!.user.canAdminister &&
          !session.user.mustChangePassword &&
          widget.gateCurrent() &&
          TickerMode.valuesOf(context).enabled &&
          (ModalRoute.of(context)?.isCurrent ?? true);
    } catch (_) {
      return false;
    }
  }

  String _requestKey() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _accountChanged() {
    if (!mounted) return;
    if (_authority()) return;
    _closed = true;
    _controller?.retire();
    _controller = null;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = ref.read(serverAccountControllerProvider);
    if (_account == null) {
      _account = account;
      _generation = account.generation;
      _sessionIdentity = account.session;
      account.addListener(_accountChanged);
    } else if (!identical(_account, account)) {
      _closed = true;
      _controller?.retire();
      _controller = null;
    }
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _controller?.retire();
      _controller = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _account?.removeListener(_accountChanged);
    _controller?.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final strings = Localizations.localeOf(context).languageCode == 'tr'
        ? WorkshopStrings.tr
        : WorkshopStrings.en;
    if (_controller == null && _authority()) {
      final gateway = AccountWorkshopGateway(
        account: _account!,
        isCurrent: _authority,
      );
      _controller = WorkshopController(
        gateway: gateway,
        isCurrent: _authority,
        requestKey: _requestKey,
      );
    }
    final controller = _controller;
    if (controller != null && _authority()) {
      return WorkshopScreen(controller: controller, strings: strings);
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(strings.locked, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
