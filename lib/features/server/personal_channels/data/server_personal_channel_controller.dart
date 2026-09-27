// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_personal_channel_models.dart';
import 'server_personal_channel_api.dart';

final class ServerPersonalChannelController extends ChangeNotifier {
  ServerPersonalChannelController(this.account, {String Function()? requestId})
    : _accountGeneration = account.generation,
      _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  List<ServerPersonalChannel> channels = const [];
  ServerPersonalChannel? selected;
  ServerPersonalPlaybackSource? playback;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session?.context != null &&
      account.session?.sessionFamilyId != null &&
      account.session?.authMutationPending == false &&
      account.session?.user.mustChangePassword == false;

  void _accountChanged() {
    if (!_authorized) retire();
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    failure = null;
    channels = const [];
    selected = null;
    playback = null;
    notifyListeners();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (client, valid) async {
        channels = await client.list(current: valid);
        final retained = selected;
        selected = retained == null
            ? null
            : channels.cast<ServerPersonalChannel?>().firstWhere(
                (channel) => channel?.id == retained.id,
                orElse: () => null,
              );
      });

  Future<void> create({
    required String name,
    required DateTime startsAt,
    required bool loop,
    required List<ServerPersonalChannelSource> sources,
    required bool Function() current,
  }) => _run(current, (client, valid) async {
    selected = await client.create(
      name: name,
      startsAt: startsAt,
      loop: loop,
      sources: sources,
      current: valid,
    );
    _upsertSelected();
  });

  Future<void> select(
    String channelId, {
    DateTime? from,
    DateTime? until,
    required bool Function() current,
  }) => _run(current, (client, valid) async {
    selected = await client.read(
      channelId,
      from: from,
      until: until,
      current: valid,
    );
    playback = null;
    _upsertSelected();
  });

  Future<void> reschedule({
    required ServerPersonalProgramme programme,
    required ServerPersonalChannelSource replacement,
    required bool Function() current,
  }) => selected == null
      ? Future.value()
      : _run(current, (client, valid) async {
          selected = await client.reschedule(
            channel: selected!,
            programme: programme,
            replacement: replacement,
            current: valid,
          );
          playback = null;
          _upsertSelected();
        });

  void _upsertSelected() {
    final value = selected;
    if (value == null) return;
    channels = [value, ...channels.where((channel) => channel.id != value.id)];
  }

  Future<void> resolve({
    required ServerPersonalProgramme programme,
    required ServerPersonalPlaybackMode mode,
    required bool Function() current,
  }) => selected == null
      ? Future.value()
      : _run(current, (client, valid) async {
          playback = await client.resolve(
            channel: selected!,
            programme: programme,
            mode: mode,
            current: valid,
          );
        });

  Future<void> cancel({required bool Function() current}) => selected == null
      ? Future.value()
      : _run(current, (client, valid) async {
          selected = await client.cancel(selected!, current: valid);
          playback = null;
          channels = channels
              .where((channel) => channel.id != selected!.id)
              .toList(growable: false);
        });

  Future<void> _run(
    bool Function() current,
    Future<void> Function(
      ServerPersonalChannelApi client,
      bool Function() valid,
    )
    action,
  ) async {
    bool routeCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (_disposed || busy || !_authorized || !routeCurrent()) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && routeCurrent();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        await action(
          ServerPersonalChannelApi(api, session, requestId: _requestId),
          () => valid() && identical(account.session, session),
        );
      });
    } on LarenorServerException catch (error) {
      if (valid()) failure = error.code;
    } catch (_) {
      if (valid()) failure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
