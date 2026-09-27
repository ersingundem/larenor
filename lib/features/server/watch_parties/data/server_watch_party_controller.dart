import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../../media_segments/domain/server_media_segment_models.dart';
import '../domain/server_watch_party_models.dart';
import 'server_watch_party_api.dart';

final class ServerWatchPartyController extends ChangeNotifier {
  ServerWatchPartyController(this.account)
    : _accountGeneration = account.generation {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerWatchPartySnapshot? snapshot;
  ServerWatchPartyInvitation? invitation;

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
    snapshot = null;
    invitation = null;
    notifyListeners();
  }

  Future<void> createCurrentItem(
    String itemId, {
    required bool Function() current,
  }) => _run(current, (api, session, valid) async {
    final normalized = serverMediaSegmentItemId(itemId);
    final catalog = ServerMediaCatalogApi(api, session.accessToken);
    final target = await catalog.discoverTarget(current: valid);
    final page = await catalog.resolveVerifiedTarget(
      target: target,
      itemId: normalized,
      current: valid,
    );
    if (!valid()) throw const LarenorServerException('retired');
    final source = ServerMediaSegmentSource.fromCatalog(
      page,
      page.items.single,
    );
    final result = await ServerWatchPartyApi(
      api,
      session,
    ).create(source, expiresAt: DateTime.now().add(const Duration(hours: 4)));
    invitation = result.invitation;
    return result.snapshot;
  });

  Future<void> join(
    String value, {
    required String itemId,
    required bool Function() current,
  }) => _run(current, (api, session, valid) async {
    final parsed = ServerWatchPartyInvitation.parse(value);
    if (parsed.itemId != serverMediaSegmentItemId(itemId)) {
      throw const LarenorServerException('invalid_request');
    }
    final result = await ServerWatchPartyApi(api, session).join(parsed);
    if (result.itemId != serverMediaSegmentItemId(itemId)) {
      throw const LarenorServerException('invalid_request');
    }
    invitation = null;
    return result;
  });

  Future<void> refresh({required bool Function() current}) => snapshot == null
      ? Future.value()
      : _run(current, (api, session, valid) {
          return ServerWatchPartyApi(api, session).refresh(snapshot!.roomId);
        });

  Future<void> report({
    required ServerWatchPartyTarget target,
    required ServerWatchPartyPlayback playback,
    required bool Function() current,
  }) => snapshot == null
      ? Future.value()
      : _run(current, (api, session, valid) {
          return ServerWatchPartyApi(
            api,
            session,
          ).report(snapshot: snapshot!, target: target, playback: playback);
        });

  Future<void> command({
    required String action,
    required Duration position,
    required bool Function() current,
  }) => snapshot == null
      ? Future.value()
      : _run(current, (api, session, valid) {
          return ServerWatchPartyApi(api, session).command(
            snapshot: snapshot!,
            action: action,
            positionMs: position.inMilliseconds,
          );
        });

  Future<void> leave({required bool Function() current}) async {
    final selected = snapshot;
    if (selected == null || busy || !_authorized) return;
    final operation = ++_epoch;
    busy = true;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        await ServerWatchPartyApi(api, session).leave(selected);
      });
      if (!_disposed && operation == _epoch && current()) retire();
    } on LarenorServerException catch (error) {
      if (!_disposed && operation == _epoch) failure = error.code;
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> _run(
    bool Function() current,
    Future<ServerWatchPartySnapshot> Function(
      LarenorServerApi api,
      ServerSession session,
      bool Function() valid,
    )
    action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && current();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final value = await action(api, session, valid);
        if (valid() && identical(account.session, session)) {
          snapshot = value;
          final retained = invitation;
          if (retained != null && retained.roomId == value.roomId) {
            invitation = ServerWatchPartyInvitation(
              roomId: retained.roomId,
              roomRevision: value.revision,
              itemId: retained.itemId,
              inviteCode: retained.inviteCode,
            );
          }
        }
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
