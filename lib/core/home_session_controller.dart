import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/server/data/server_account_controller.dart';
import 'app_interaction_scope.dart';
import 'home_source_store.dart';

final homeSessionControllerProvider = Provider<HomeSessionController?>(
  (_) => null,
);

/// Device source and verified identity outlive each disposable home runtime.
class HomeSessionController extends ChangeNotifier {
  HomeSessionController({required this.store, required this.account}) {
    account.addListener(_accountChanged);
  }

  final HomeSourcePersistence store;
  final ServerAccountController account;
  final interaction = AppInteractionController(active: false);
  HomeSource? _source;
  HomeSource? get source => _source;
  bool _busy = true;
  bool get busy => _busy;
  String? _failure;
  String? get failure => _failure;
  bool _disposed = false;
  int _operation = 0;
  (String, String, String)? _coreIdentity;
  Object _identity = 'recovery';
  Object get runtimeIdentity => _identity;
  bool get usesLocalHome => _identity == HomeSource.directLocal;

  Future<void> initialize() async {
    final operation = ++_operation;
    _busy = true;
    _failure = null;
    _synchronize();
    try {
      final source = await store.read();
      if (!_current(operation)) return;
      _source = source;
    } catch (_) {
      if (!_current(operation)) return;
      _failure = 'source_read_failed';
    }
    if (!_current(operation)) return;
    _busy = false;
    _synchronize();
    _restoreCoreAccount();
  }

  Future<void> choose(HomeSource source) async {
    if (_disposed || _busy) return;
    final operation = ++_operation;
    _busy = true;
    _failure = null;
    // Retirement happens before the first asynchronous preference operation.
    _synchronize();
    try {
      await store.write(source);
      if (!_current(operation)) return;
      _source = source;
      _coreIdentity = null;
    } catch (_) {
      if (!_current(operation)) return;
      _failure = 'source_write_failed';
    }
    if (!_current(operation)) return;
    _busy = false;
    _synchronize();
    if (_failure == null) _restoreCoreAccount();
  }

  bool _current(int operation) => !_disposed && operation == _operation;

  void _restoreCoreAccount() {
    if (_source == HomeSource.verifiedCore &&
        !account.initialized &&
        !account.working) {
      unawaited(account.initialize());
    }
  }

  void _accountChanged() {
    if (_disposed || _source != HomeSource.verifiedCore) return;
    _synchronize();
  }

  void _synchronize() {
    final session = account.session;
    final context = session?.context;
    if (_source == HomeSource.verifiedCore) {
      if (context != null && session!.user.mustChangePassword == false) {
        _coreIdentity = (context.coreId, context.homeId, session.user.id);
      } else if (!account.working && !account.hasPendingContext) {
        _coreIdentity = null;
      }
    }
    final Object next = _busy || _failure != null || _source == null
        ? 'recovery'
        : _source == HomeSource.directLocal
        ? HomeSource.directLocal
        : (HomeSource.verifiedCore, _coreIdentity);
    if (next != _identity) {
      interaction.setActive(false);
      _identity = next;
    }
    notifyListeners();
  }

  void runtimeMounted(Object identity) {
    if (!_disposed && identity == _identity) interaction.setActive(true);
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    account.removeListener(_accountChanged);
    interaction.dispose();
    super.dispose();
  }
}
