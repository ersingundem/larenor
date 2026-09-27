import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_ai_memory_models.dart';
import 'server_ai_memory_api.dart';

final class ServerAiMemoryController extends ChangeNotifier {
  ServerAiMemoryController(this.account)
    : _generation = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl,
      _context = account.session?.context {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _generation;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  int _epoch = 0;
  bool _disposed = false, busy = false, needsRefresh = false;
  String? failure, announcement;
  AiMemorySnapshot? value;

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        _accountId != null &&
        account.isCurrent(_generation) &&
        account.initialized &&
        !account.working &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint &&
        session?.context == _context;
  }

  static String _requestKey() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return 'memory:${bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = needsRefresh = false;
    failure = announcement = null;
    value = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api) => api.snapshot());

  Future<void> remember(
    String content,
    int durationSeconds, {
    required bool Function() current,
  }) => _mutate(
    current,
    (api) => api.remember(
      requestKey: _requestKey(),
      content: content,
      durationSeconds: durationSeconds,
    ),
    'created',
  );

  Future<void> correct(
    AiMemoryRecord memory,
    String content,
    int durationSeconds, {
    required bool Function() current,
  }) => _mutate(
    current,
    (api) => api.correct(
      memory,
      requestKey: _requestKey(),
      content: content,
      durationSeconds: durationSeconds,
    ),
    'corrected',
  );

  Future<void> forget(
    AiMemoryRecord memory, {
    required bool Function() current,
  }) async {
    await _run(
      current,
      (api) async {
        await api.forget(memory, _requestKey());
        return api.snapshot();
      },
      mutation: true,
      success: 'forgotten',
    );
  }

  Future<void> _mutate(
    bool Function() current,
    Future<AiMemoryRecord> Function(ServerAiMemoryApi api) action,
    String success,
  ) => _run(
    current,
    (api) async {
      await action(api);
      return api.snapshot();
    },
    mutation: true,
    success: success,
  );

  Future<void> _run(
    bool Function() current,
    Future<AiMemorySnapshot> Function(ServerAiMemoryApi api) action, {
    bool mutation = false,
    String? success,
  }) async {
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        (mutation && needsRefresh)) {
      return;
    }
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = announcement = null;
    _emit();
    try {
      final next = await account.withSession((raw, session) {
        if (!valid()) throw const LarenorServerException('cancelled');
        return action(
          ServerAiMemoryApi(raw, session.accessToken, _context!, _accountId!),
        );
      });
      if (!valid()) return;
      value = next;
      needsRefresh = false;
      announcement = success;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
