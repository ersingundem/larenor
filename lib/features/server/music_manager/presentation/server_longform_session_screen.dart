import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../data/server_longform_session_api.dart';
import '../data/server_music_manager_api.dart';
import '../domain/server_longform_session_models.dart';
import '../domain/server_music_manager_models.dart';

class ServerLongformSessionScreen extends StatefulWidget {
  const ServerLongformSessionScreen({
    super.key,
    required this.account,
    required this.manager,
    required this.item,
    this.initialReceiverId,
  });

  final ServerAccountController account;
  final ServerMusicManager manager;
  final ServerMusicLongformItem item;
  final String? initialReceiverId;

  @override
  State<ServerLongformSessionScreen> createState() =>
      _ServerLongformSessionScreenState();
}

class _ServerLongformSessionScreenState
    extends State<ServerLongformSessionScreen> {
  late ServerMusicManager _manager;
  late final int _accountEpoch;
  ServerLongformSession? _session;
  String? _receiverId, _failure;
  double _position = 0;
  int? _sleepMinutes;
  bool _busy = true, _saved = false;
  int _epoch = 0;

  bool get _current =>
      mounted &&
      widget.account.isCurrent(_accountEpoch) &&
      widget.account.initialized &&
      !widget.account.working;

  ServerMusicReceiver? get _receiver => _manager.receivers
      .where(
        (value) => value.id == _receiverId && value.available && value.enabled,
      )
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager;
    _accountEpoch = widget.account.generation;
    _receiverId = widget.initialReceiverId;
    if (_receiver == null) {
      _receiverId = _manager.receivers
          .where((value) => value.available && value.enabled)
          .firstOrNull
          ?.id;
    }
    unawaited(_open());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Future<void> _open({bool takeover = false}) async {
    if (!_current) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _failure = null;
      _saved = false;
    });
    try {
      final value = await widget.account.withSession(
        (api, login) => ServerLongformSessionApi(
          api,
          login.accessToken,
        ).open(manager: _manager, item: widget.item, takeover: takeover),
      );
      if (!_current || epoch != _epoch) return;
      setState(() {
        _session = value;
        _position = value.positionSeconds;
        _sleepMinutes = _remainingSleepMinutes(value.sleepTimerEndsAt);
      });
    } catch (error) {
      if (_current && epoch == _epoch) {
        setState(() => _failure = _code(error));
      }
    } finally {
      if (_current && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _save({
    ServerLongformPlaybackState? state,
    ServerMusicManager? manager,
    bool takeover = false,
  }) async {
    final before = _session;
    final authority = manager ?? _manager;
    if (!_current || _busy || before == null) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _failure = null;
      _saved = false;
    });
    try {
      final now = DateTime.now().toUtc();
      final result = await widget.account.withSession(
        (api, login) => ServerLongformSessionApi(api, login.accessToken).update(
          manager: authority,
          item: widget.item,
          session: before,
          positionSeconds: _position,
          playbackState: state ?? before.playbackState,
          bookmarks: before.bookmarks,
          sleepTimerEndsAt: _sleepMinutes == null
              ? null
              : now.add(Duration(minutes: _sleepMinutes!)),
          takeover: takeover,
        ),
      );
      if (!_current || epoch != _epoch) return;
      setState(() {
        _manager = authority;
        _session = result;
        _saved = true;
      });
    } catch (error) {
      if (_current && epoch == _epoch) {
        setState(() => _failure = _code(error));
      }
    } finally {
      if (_current && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _replaceBookmarks(List<ServerLongformBookmark> values) async {
    final before = _session;
    if (before == null || !before.ownedByCurrentSession) return;
    final copied = ServerLongformSession.fromJson({
      'schemaVersion': 1,
      'sessionId': before.id,
      'revision': before.revision,
      'coreId': before.coreId,
      'homeId': before.homeId,
      'accountId': before.accountId,
      'installationId': before.installationId,
      'installationRevision': before.installationRevision,
      'coreRevision': before.coreRevision,
      'managerRevision': before.managerRevision,
      'providerInstanceId': before.providerInstanceId,
      'mediaUri': before.mediaUri,
      'mediaType': before.mediaType,
      'title': before.title,
      'durationSeconds': before.durationSeconds,
      'positionSeconds': before.positionSeconds,
      'playbackState': before.playbackState.name,
      'sleepTimerEndsAt': before.sleepTimerEndsAt == null
          ? null
          : before.sleepTimerEndsAt!.millisecondsSinceEpoch ~/ 1000,
      'bookmarks': values.map((value) => value.toJson()).toList(),
      'ownedByCurrentSession': before.ownedByCurrentSession,
      'updatedAt': before.updatedAt.millisecondsSinceEpoch ~/ 1000,
    });
    setState(() => _session = copied);
    await _save();
  }

  Future<void> _play() async {
    final before = _session;
    final receiver = _receiver;
    if (!_current ||
        _busy ||
        before == null ||
        !before.ownedByCurrentSession ||
        receiver == null ||
        !receiver.supports(ServerMusicOperation.queueReplace)) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _failure = null;
      _saved = false;
    });
    try {
      final result = await widget.account.withSession((api, login) async {
        final client = ServerMusicManagerApi(api, login.accessToken);
        var current = await _commandAndRead(
          client,
          _manager,
          receiver,
          ServerMusicOperation.queueReplace,
          mediaUris: [widget.item.uri],
        );
        var currentReceiver = _findReceiver(current, receiver.id);
        if (_position > 0 &&
            _position <= 864000 &&
            currentReceiver.supports(ServerMusicOperation.seek)) {
          current = await _commandAndRead(
            client,
            current,
            currentReceiver,
            ServerMusicOperation.seek,
            positionSeconds: _position,
          );
          currentReceiver = _findReceiver(current, receiver.id);
        }
        if (currentReceiver.supports(ServerMusicOperation.play) &&
            currentReceiver.playbackState != 'playing') {
          current = await _commandAndRead(
            client,
            current,
            currentReceiver,
            ServerMusicOperation.play,
          );
        }
        final nextSession =
            await ServerLongformSessionApi(api, login.accessToken).update(
              manager: current,
              item: widget.item,
              session: before,
              positionSeconds: _position,
              playbackState: ServerLongformPlaybackState.playing,
              bookmarks: before.bookmarks,
              sleepTimerEndsAt: _sleepMinutes == null
                  ? null
                  : DateTime.now().toUtc().add(
                      Duration(minutes: _sleepMinutes!),
                    ),
            );
        return (current, nextSession);
      });
      if (!_current || epoch != _epoch) return;
      setState(() {
        _manager = result.$1;
        _session = result.$2;
        _receiverId = receiver.id;
        _saved = true;
      });
    } catch (error) {
      if (_current && epoch == _epoch) {
        setState(() => _failure = _code(error));
      }
    } finally {
      if (_current && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _pause() async {
    final before = _session;
    final receiver = _receiver;
    if (!_current ||
        _busy ||
        before == null ||
        !before.ownedByCurrentSession ||
        receiver == null ||
        !receiver.supports(ServerMusicOperation.pause)) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _failure = null;
      _saved = false;
    });
    try {
      final result = await widget.account.withSession((api, login) async {
        final client = ServerMusicManagerApi(api, login.accessToken);
        final current = await _commandAndRead(
          client,
          _manager,
          receiver,
          ServerMusicOperation.pause,
        );
        final nextSession =
            await ServerLongformSessionApi(api, login.accessToken).update(
              manager: current,
              item: widget.item,
              session: before,
              positionSeconds: _position,
              playbackState: ServerLongformPlaybackState.paused,
              bookmarks: before.bookmarks,
            );
        return (current, nextSession);
      });
      if (!_current || epoch != _epoch) return;
      setState(() {
        _manager = result.$1;
        _session = result.$2;
        _saved = true;
      });
    } catch (error) {
      if (_current && epoch == _epoch) {
        setState(() => _failure = _code(error));
      }
    } finally {
      if (_current && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<ServerMusicManager> _commandAndRead(
    ServerMusicManagerApi client,
    ServerMusicManager manager,
    ServerMusicReceiver receiver,
    ServerMusicOperation operation, {
    double? positionSeconds,
    List<String> mediaUris = const [],
  }) async {
    final requestId = _randomId();
    final receipt = await client.command(
      requestId: requestId,
      manager: manager,
      receiver: receiver,
      operation: operation,
      positionSeconds: positionSeconds,
      mediaUris: mediaUris,
    );
    if (!receipt.authenticated) {
      throw const LarenorServerException('effect_unknown');
    }
    final after = await client.read(manager.installationId);
    if (after.revision != receipt.playerRevision) {
      throw const LarenorServerException('effect_unknown');
    }
    return after;
  }

  ServerMusicReceiver _findReceiver(ServerMusicManager value, String id) =>
      value.receivers
          .where((item) => item.id == id && item.available && item.enabled)
          .firstOrNull ??
      (throw const LarenorServerException('effect_unknown'));

  Future<void> _chooseReceiver() async {
    final options = _manager.receivers
        .where((value) => value.available && value.enabled)
        .toList(growable: false);
    final result = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          for (final receiver in options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, receiver.id),
              child: Text(receiver.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (_current && result != null) setState(() => _receiverId = result);
  }

  int? _remainingSleepMinutes(DateTime? end) {
    if (end == null) return null;
    final seconds = end.difference(DateTime.now().toUtc()).inSeconds;
    return seconds < 60 ? null : (seconds / 60).ceil();
  }

  String _format(double seconds) {
    final total = seconds.round();
    final hours = total ~/ 3600;
    final minutes = total % 3600 ~/ 60;
    final rest = total % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  String _code(Object error) =>
      error is LarenorServerException ? error.code : 'connection_failed';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final session = _session;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.serverMusicLongformHubTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(l.serverMusicLongformHubIntro),
            ),
            if (_busy && session == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CupertinoActivityIndicator()),
              )
            else if (session == null)
              SettingsSection(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l.serverMusicLongformSessionError),
                  ),
                  SettingsActionTile(
                    title: Text(l.commonRetry),
                    onTap: _busy ? null : _open,
                  ),
                ],
              )
            else ...[
              _progressSection(l, session),
              if (!session.ownedByCurrentSession)
                SettingsSection(
                  footer: Text(l.serverMusicLongformOtherSession),
                  children: [
                    SettingsActionTile(
                      title: Text(l.serverMusicLongformTakeOver),
                      onTap: _busy ? null : () => _open(takeover: true),
                    ),
                  ],
                )
              else ...[
                _playbackSection(l, session),
                _bookmarkSection(l, session),
                if (widget.item.chapters.isNotEmpty) _chaptersSection(l),
              ],
            ],
            if (_busy && session != null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (_failure != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Semantics(
                  liveRegion: true,
                  child: Text(l.serverMusicLongformSessionError),
                ),
              ),
            if (_saved)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Semantics(
                  liveRegion: true,
                  child: Text(l.serverMusicLongformSaved),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _progressSection(AppLocalizations l, ServerLongformSession session) =>
      SettingsSection(
        header: Text(
          session.mediaType == 'audiobook'
              ? l.serverMusicLongformAudiobook
              : l.serverMusicLongformPodcastEpisode,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(session.title, style: AppText.headline),
                const SizedBox(height: 12),
                CupertinoSlider(
                  value: _position.clamp(0, session.durationSeconds),
                  max: session.durationSeconds,
                  onChanged: session.ownedByCurrentSession && !_busy
                      ? (value) => setState(() {
                          _position = value;
                          _saved = false;
                        })
                      : null,
                ),
                Text(
                  '${_format(_position)} / ${_format(session.durationSeconds)}',
                ),
              ],
            ),
          ),
        ],
      );

  Widget _playbackSection(AppLocalizations l, ServerLongformSession session) =>
      SettingsSection(
        header: Text(l.serverMusicManagerPlayback),
        children: [
          SettingsActionTile(
            title: Text(_receiver?.name ?? l.serverMusicLongformChooseReceiver),
            leading: const Icon(CupertinoIcons.hifispeaker),
            onTap: _busy ? null : _chooseReceiver,
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: CupertinoButton.filled(
                    onPressed: _busy ? null : _play,
                    child: Text(l.serverMusicLongformResume),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CupertinoButton(
                    onPressed: _busy ? null : _pause,
                    child: Text(l.serverMusicLongformPause),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.serverMusicLongformSleepTimer),
                const SizedBox(height: 8),
                IgnorePointer(
                  ignoring: _busy,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _sleepMinutes ?? 0,
                    children: {
                      0: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(l.serverMusicLongformSleepOff),
                      ),
                      for (final minutes in const [15, 30, 60])
                        minutes: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text('$minutes'),
                        ),
                    },
                    onValueChanged: (value) => setState(() {
                      if (_busy) return;
                      _sleepMinutes = value == 0 ? null : value;
                      _saved = false;
                    }),
                  ),
                ),
                const SizedBox(height: 12),
                CupertinoButton(
                  onPressed: _busy ? null : _save,
                  child: Text(l.serverMusicLongformSave),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _bookmarkSection(AppLocalizations l, ServerLongformSession session) =>
      SettingsSection(
        header: Text(l.serverMusicLongformBookmarks),
        children: [
          SettingsActionTile(
            title: Text(l.serverMusicLongformAddBookmark),
            leading: const Icon(CupertinoIcons.bookmark),
            onTap: _busy || session.bookmarks.length >= 64
                ? null
                : () {
                    final chapter = widget.item.chapters
                        .where((value) => value.startSeconds <= _position)
                        .lastOrNull;
                    unawaited(
                      _replaceBookmarks([
                        ...session.bookmarks,
                        ServerLongformBookmark(
                          id: _randomId(),
                          positionSeconds: _position,
                          label: chapter?.name ?? _format(_position),
                        ),
                      ]),
                    );
                  },
          ),
          for (final bookmark in session.bookmarks)
            SettingsActionTile(
              title: Text(bookmark.label),
              additionalInfo: Text(_format(bookmark.positionSeconds)),
              onTap: _busy
                  ? null
                  : () => setState(() => _position = bookmark.positionSeconds),
              leading: const Icon(CupertinoIcons.bookmark_fill),
            ),
          for (final bookmark in session.bookmarks)
            SettingsActionTile(
              title: Text(
                '${l.serverMusicLongformRemoveBookmark}: ${bookmark.label}',
              ),
              leading: const Icon(CupertinoIcons.delete),
              onTap: _busy
                  ? null
                  : () => unawaited(
                      _replaceBookmarks(
                        session.bookmarks
                            .where((value) => value.id != bookmark.id)
                            .toList(growable: false),
                      ),
                    ),
            ),
        ],
      );

  Widget _chaptersSection(AppLocalizations l) => SettingsSection(
    header: Text(l.serverMusicLongformChapters),
    children: [
      for (final chapter in widget.item.chapters)
        SettingsActionTile(
          title: Text(chapter.name),
          additionalInfo: Text(_format(chapter.startSeconds)),
          onTap: _busy
              ? null
              : () => setState(() {
                  _position = chapter.startSeconds;
                  _saved = false;
                }),
        ),
    ],
  );
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
