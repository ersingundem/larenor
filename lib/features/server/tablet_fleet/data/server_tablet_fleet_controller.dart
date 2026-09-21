import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_tablet_fleet_models.dart';
import 'server_tablet_fleet_api.dart';

final class _PendingTabletIssue {
  const _PendingTabletIssue({
    required this.tabletId,
    required this.tabletRevision,
    required this.command,
    required this.requestKey,
    required this.expiresAt,
  });
  final String tabletId, requestKey;
  final int tabletRevision;
  final TabletCommandKind command;
  final double expiresAt;
}

/// Route-owned administrator authority. A hidden route, changed account,
/// changed Core/home or uncertain mutation retires every pending callback.
class ServerTabletFleetController extends ChangeNotifier {
  ServerTabletFleetController(
    this.account, {
    String Function()? requestKey,
    double Function()? clock,
  }) : _accountEpoch = account.generation,
       _accountId = account.session?.user.id,
       _endpoint = account.session?.endpoint.baseUrl,
       _context = account.session?.context,
       _requestKey = requestKey ?? _randomRequestKey,
       _clock = clock ?? _nowSeconds {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  final String Function() _requestKey;
  final double Function() _clock;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, needsRefresh = false;
  String? failure;
  String? announcement;
  List<ManagedTablet> tablets = const [];
  Map<String, ManagedTabletCommand> latestCommands = const {};
  _PendingTabletIssue? _uncertainIssue;

  static String _randomRequestKey() {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'client:$value';
  }

  static double _nowSeconds() =>
      DateTime.now().millisecondsSinceEpoch / Duration.millisecondsPerSecond;

  static bool _outcomeMayBeUnknown(String? code) => {
    'connection_failed',
    'timeout',
    'server_error',
    'invalid_response',
    'tablet_fleet_storage_unavailable',
  }.contains(code);

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        account.isCurrent(_accountEpoch) &&
        account.initialized &&
        !account.working &&
        session?.user.canAdminister == true &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint &&
        session?.context == _context;
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    needsRefresh = false;
    failure = null;
    announcement = null;
    tablets = const [];
    latestCommands = const {};
    _uncertainIssue = null;
    _emit();
  }

  bool _current(int epoch, bool Function() current) =>
      !_disposed && epoch == _epoch && _authorized && current();

  Future<void> load({required bool Function() current}) =>
      _run(current, (api, valid) async {
        final value = await api.list();
        if (!valid()) return;
        tablets = value;
        final pending = _uncertainIssue;
        if (pending == null) return;
        final matches = value
            .where(
              (item) =>
                  item.id == pending.tabletId &&
                  item.revision == pending.tabletRevision &&
                  item.state == TabletFleetState.active &&
                  item.supports(pending.command),
            )
            .toList();
        if (matches.length != 1) {
          throw const LarenorServerException('tablet_device_changed');
        }
        if (pending.expiresAt <= _clock()) {
          _uncertainIssue = null;
          throw const LarenorServerException('tablet_command_expired');
        }
        final ManagedTabletCommand receipt;
        try {
          receipt = await api.issueVerified(
            matches.single,
            pending.command,
            requestKey: pending.requestKey,
            expiresAt: pending.expiresAt,
          );
        } on LarenorServerException catch (error) {
          if (!_outcomeMayBeUnknown(error.code)) _uncertainIssue = null;
          rethrow;
        }
        if (!valid() || !identical(_uncertainIssue, pending)) return;
        latestCommands = Map.unmodifiable({
          ...latestCommands,
          pending.tabletId: receipt,
        });
        _uncertainIssue = null;
        announcement = 'command_verified';
      });

  Future<void> advanceProfile(
    ManagedTablet tablet, {
    required bool Function() current,
  }) => _mutate(current, tablet, (api) {
    if (tablet.desiredProfileRevision == 9223372036854775807) {
      throw const LarenorServerException('invalid_request');
    }
    return api.updateProfile(tablet, tablet.desiredProfileRevision + 1);
  }, announcementCode: 'profile_updated');

  Future<void> revoke(
    ManagedTablet tablet, {
    required bool Function() current,
  }) => _mutate(
    current,
    tablet,
    (api) => api.revoke(tablet),
    announcementCode: 'tablet_revoked',
  );

  Future<void> issue(
    ManagedTablet tablet,
    TabletCommandKind command, {
    required bool Function() current,
  }) async {
    if (!tablet.supports(command) || _uncertainIssue != null) return;
    final epoch = _epoch;
    final pending = _PendingTabletIssue(
      tabletId: tablet.id,
      tabletRevision: tablet.revision,
      command: command,
      requestKey: _requestKey(),
      expiresAt: _clock() + 60,
    );
    await _run(
      current,
      (api, valid) async {
        _uncertainIssue = pending;
        final receipt = await api.issueVerified(
          tablet,
          command,
          requestKey: pending.requestKey,
          expiresAt: pending.expiresAt,
        );
        if (!valid() || !identical(_uncertainIssue, pending)) return;
        latestCommands = Map.unmodifiable({
          ...latestCommands,
          tablet.id: receipt,
        });
        _uncertainIssue = null;
        announcement = 'command_verified';
      },
      mutation: true,
      expectedEpoch: epoch,
    );
    if (failure != null && !_outcomeMayBeUnknown(failure)) {
      _uncertainIssue = null;
    }
  }

  Future<void> _mutate(
    bool Function() current,
    ManagedTablet tablet,
    Future<ManagedTablet> Function(ServerTabletFleetApi api) action, {
    required String announcementCode,
  }) async {
    final epoch = _epoch;
    await _run(
      current,
      (api, valid) async {
        final value = await action(api);
        if (!valid()) return;
        final old = tablets.where((item) => item.id == tablet.id).toList();
        if (old.length != 1 || !old.single.sameAuthority(value)) {
          throw const LarenorServerException('invalid_response');
        }
        tablets = List.unmodifiable(
          tablets.map((item) => item.id == value.id ? value : item),
        );
        announcement = announcementCode;
      },
      mutation: true,
      expectedEpoch: epoch,
    );
  }

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerTabletFleetApi api, bool Function() valid)
    action, {
    bool mutation = false,
    int? expectedEpoch,
  }) async {
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        (mutation && needsRefresh)) {
      return;
    }
    final epoch = expectedEpoch ?? _epoch;
    bool valid() => _current(epoch, current);
    busy = true;
    failure = null;
    announcement = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid() ||
            session.user.id != _accountId ||
            session.endpoint.baseUrl != _endpoint ||
            session.context != _context) {
          throw const LarenorServerException('cancelled');
        }
        await action(
          ServerTabletFleetApi(raw, session.accessToken, _context!),
          valid,
        );
      });
      if (valid()) needsRefresh = false;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
      if ({
        'invalid_response',
        'unauthorized',
        'forbidden',
        'password_change_required',
      }.contains(failure)) {
        tablets = const [];
        latestCommands = const {};
      }
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

/// Memory-only device flow. Command envelopes are retained by sequence so a
/// replayed poll never becomes a second execution. This class performs no
/// Android Device Owner action; the caller must report an explicit result.
class TabletFleetDeviceSessionController extends ChangeNotifier {
  TabletFleetDeviceSessionController(this.account)
    : _accountEpoch = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl,
      _context = account.session?.context {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ManagedTablet? tablet;
  Map<int, ManagedTabletCommand> commands = const {};

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        account.isCurrent(_accountEpoch) &&
        account.initialized &&
        !account.working &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint &&
        session?.context == _context;
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void attach(ManagedTablet value) {
    if (!_authorized || value.context != _context) return;
    tablet = value;
    commands = const {};
    _emit();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    tablet = null;
    commands = const {};
    _emit();
  }

  Future<void> poll({required bool Function() current}) async {
    final bound = tablet;
    if (bound == null || busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        identical(tablet, bound);
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        final page = await ServerTabletFleetApi(
          raw,
          session.accessToken,
          _context!,
        ).poll(bound, after: commands.keys.fold(0, max));
        if (!valid()) return;
        final merged = Map<int, ManagedTabletCommand>.of(commands);
        for (final command in page.commands) {
          final old = merged[command.sequence];
          if (old != null && !old.sameReceipt(command)) {
            throw const LarenorServerException('invalid_response');
          }
          merged[command.sequence] = command;
        }
        commands = Map.unmodifiable(merged);
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        if (failure == 'invalid_response' ||
            failure == 'unauthorized' ||
            failure == 'forbidden') {
          commands = const {};
        }
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> complete(
    ManagedTabletCommand command,
    TabletCommandResult result, {
    required bool Function() current,
  }) async {
    final bound = tablet;
    final known = commands[command.sequence];
    if (bound == null ||
        known == null ||
        !known.sameReceipt(command) ||
        busy ||
        !_authorized ||
        !current()) {
      return;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        identical(tablet, bound) &&
        identical(commands[command.sequence], known);
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        final receipt =
            await ServerTabletFleetApi(
              raw,
              session.accessToken,
              _context!,
            ).completeVerified(
              bound,
              command,
              result,
              appliedProfileRevision: bound.appliedProfileRevision,
            );
        if (valid()) {
          commands = Map.unmodifiable({...commands, command.sequence: receipt});
        }
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
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
