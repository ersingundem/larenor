import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../shared/utils/foreground_poller.dart';
import '../domain/music_models.dart';
import 'music_api.dart';

/// One read in flight, no overlapping poll or automatic mutation. Hidden routes
/// must release their provider subscription; app lifecycle is enforced here too.
class MusicQueueController {
  MusicQueueController({
    required this.read,
    DateTime Function()? now,
    Duration interval = const Duration(seconds: 30),
  }) : now = now ?? DateTime.now {
    _poller = ForegroundPoller(interval: interval, poll: _refresh);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final next = state == AppLifecycleState.resumed;
        if (next == _foreground) return;
        _foreground = next;
        _epoch++;
        if (!next) {
          _publish(
            MusicRead(
              value: _state.value,
              readAt: _state.readAt,
              isPaused: true,
            ),
          );
        }
      },
    );
  }
  final Future<MusicQueueSummary> Function() read;
  final DateTime Function() now;
  final _changes = StreamController<MusicRead<MusicQueueSummary>>.broadcast();
  late final ForegroundPoller _poller;
  late final AppLifecycleListener _lifecycle;
  var _state = const MusicRead<MusicQueueSummary>(isLoading: true);
  var _closed = false, _foreground = true;
  var _epoch = 0;
  MusicRead<MusicQueueSummary> get state => _state;
  Stream<MusicRead<MusicQueueSummary>> get changes => Stream.multi((sink) {
    if (_closed) {
      sink.close();
      return;
    }
    final subscription = _changes.stream.listen(
      sink.addSync,
      onError: sink.addErrorSync,
      onDone: sink.closeSync,
    );
    sink.addSync(_state);
    sink.onCancel = () {
      unawaited(subscription.cancel());
    };
  });
  void start() {
    if (!_closed) _poller.start();
  }

  void stop() {
    if (_closed) return;
    _epoch++;
    _poller.stop();
    _publish(
      MusicRead(value: _state.value, readAt: _state.readAt, isPaused: true),
    );
  }

  void refresh() {
    if (!_closed) _poller.refresh();
  }

  void _publish(MusicRead<MusicQueueSummary> value) {
    if (_closed) return;
    _state = value;
    _changes.add(value);
  }

  Future<void> _refresh() async {
    final epoch = _epoch;
    if (_closed || !_foreground) return;
    _publish(
      MusicRead(value: _state.value, readAt: _state.readAt, isLoading: true),
    );
    try {
      final value = await read();
      if (!_closed && _foreground && epoch == _epoch) {
        _publish(MusicRead(value: value, readAt: now().toUtc()));
      }
    } catch (error) {
      if (!_closed && _foreground && epoch == _epoch) {
        _publish(
          MusicRead(
            value: _state.value,
            readAt: _state.readAt,
            failure: classifyMusicFailure(error),
          ),
        );
      }
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _poller.dispose();
    _lifecycle.dispose();
    unawaited(_changes.close());
  }
}
