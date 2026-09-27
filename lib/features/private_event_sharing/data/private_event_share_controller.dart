import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/private_event_share_models.dart';
import 'private_event_share_api.dart';

enum EventShareState { idle, loading, ready, busy, uncertain, offline, error }

class PrivateEventShareController extends ChangeNotifier {
  PrivateEventShareController(this._api, {required this.commandIds});

  final PrivateEventShareApi _api;
  final String Function() commandIds;
  EventShareState _state = EventShareState.idle;
  EventShareSnapshot? _snapshot;
  EventRedactionPreview? _preview;
  EventShareDownload? _download;
  CreatedPrivateEventShare? _created;
  int _epoch = 0;
  String? _pendingCommand;

  EventShareState get state => _state;
  EventShareSnapshot? get snapshot => _snapshot;
  EventRedactionPreview? get previewResult => _preview;
  EventShareDownload? get downloadResult => _download;
  CreatedPrivateEventShare? get createdShare => _created;

  void _set(EventShareState value) {
    _state = value;
    notifyListeners();
  }

  Future<void> load() async {
    final epoch = ++_epoch;
    _preview = null;
    _download = null;
    _set(EventShareState.loading);
    try {
      final value = await _api.snapshot();
      if (epoch != _epoch) return;
      if (value.revision < 1 ||
          value.shares.length > 256 ||
          value.audit.length > 1024) {
        _set(EventShareState.error);
        return;
      }
      _snapshot = value;
      _set(EventShareState.ready);
    } on TimeoutException {
      if (epoch == _epoch) _set(EventShareState.offline);
    } catch (_) {
      if (epoch == _epoch) _set(EventShareState.error);
    }
  }

  Future<void> preview(EventShareDraft draft) async {
    if (_state != EventShareState.ready || _pendingCommand != null) return;
    final epoch = _epoch;
    _preview = null;
    _set(EventShareState.busy);
    try {
      final value = await _api.preview(draft);
      if (epoch != _epoch) return;
      if (!value.covers(draft)) {
        _set(EventShareState.error);
        return;
      }
      _preview = value;
      _set(EventShareState.ready);
    } on TimeoutException {
      if (epoch == _epoch) _set(EventShareState.offline);
    } catch (_) {
      if (epoch == _epoch) _set(EventShareState.error);
    }
  }

  Future<void> create(EventShareDraft draft) async {
    final snapshot = _snapshot;
    final preview = _preview;
    if (_state != EventShareState.ready ||
        snapshot == null ||
        preview == null ||
        !preview.covers(draft) ||
        _pendingCommand != null) {
      return;
    }
    final epoch = _epoch;
    final command = commandIds();
    _pendingCommand = command;
    _set(EventShareState.busy);
    try {
      _created = await _api.create(
        expectedRevision: snapshot.revision,
        commandId: command,
        draft: draft,
        preview: preview,
      );
      if (epoch != _epoch) return;
      _pendingCommand = null;
      await load();
    } on TimeoutException {
      if (epoch == _epoch) _set(EventShareState.uncertain);
    } catch (_) {
      if (epoch == _epoch) {
        _pendingCommand = null;
        _set(EventShareState.error);
      }
    }
  }

  Future<void> revoke(String shareId) async {
    final snapshot = _snapshot;
    if (_state != EventShareState.ready ||
        snapshot == null ||
        _pendingCommand != null) {
      return;
    }
    final epoch = _epoch;
    final command = commandIds();
    _pendingCommand = command;
    _set(EventShareState.busy);
    try {
      await _api.revoke(
        expectedRevision: snapshot.revision,
        commandId: command,
        shareId: shareId,
      );
      if (epoch != _epoch) return;
      _pendingCommand = null;
      await load();
    } on TimeoutException {
      if (epoch == _epoch) _set(EventShareState.uncertain);
    } catch (_) {
      if (epoch == _epoch) {
        _pendingCommand = null;
        _set(EventShareState.error);
      }
    }
  }

  Future<void> download(String accessToken) async {
    if (_state != EventShareState.ready) return;
    final epoch = _epoch;
    _download = null;
    _set(EventShareState.busy);
    try {
      final value = await _api.download(
        accessToken: accessToken,
        accessId: commandIds(),
      );
      if (epoch != _epoch) return;
      if (value.bytes.isEmpty || value.bytes.length > 67108864) {
        _set(EventShareState.error);
        return;
      }
      _download = value;
      _set(EventShareState.ready);
    } on TimeoutException {
      if (epoch == _epoch) _set(EventShareState.offline);
    } catch (_) {
      if (epoch == _epoch) _set(EventShareState.error);
    }
  }

  Future<void> reconcile() async {
    if (_state != EventShareState.uncertain) return;
    _pendingCommand = null;
    await load();
  }

  void cancel() {
    _epoch++;
    _pendingCommand = null;
    _preview = null;
    _download = null;
    _created = null;
    _set(EventShareState.idle);
  }
}
