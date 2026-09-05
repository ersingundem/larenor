import 'dart:async';

import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';

LocalAudioSnapshot audioState({
  String id = 'station-one',
  bool playing = true,
  Duration? duration = const Duration(minutes: 4),
  bool seek = true,
}) => LocalAudioSnapshot(
  supported: true,
  phase: LocalAudioPhase.ready,
  sourceId: id,
  title: 'Current station',
  artist: 'Current performer',
  album: 'Current album',
  isPlaying: playing,
  position: const Duration(seconds: 42),
  duration: duration,
  canPause: playing,
  canPlay: !playing,
  canSeek: seek && duration != null,
  canStop: true,
);

class FakeLocalAudioBridge extends LocalAudioBridge {
  FakeLocalAudioBridge() : super(isAndroid: false);
  LocalAudioSnapshot current = const LocalAudioSnapshot(supported: true);
  final events = StreamController<LocalAudioSnapshot>.broadcast(sync: true);
  final plays = <LocalAudioSource>[];
  final commands = <String>[];
  final seeks = <Duration>[];
  final expectedSources = <String?>[];
  Completer<void>? playGate, snapshotGate, stopGate, powerGate;
  Object? playError, stopError, powerError;
  var snapshotReads = 0,
      powerReads = 0,
      batteryOpens = 0,
      notificationOpens = 0;
  var settingsAvailable = true;
  void emit(LocalAudioSnapshot value) {
    current = value;
    events.add(value);
  }

  @override
  Stream<LocalAudioSnapshot> get changes => Stream.multi((sink) {
    sink.add(current);
    final listener = events.stream.listen(sink.add);
    sink.onCancel = listener.cancel;
  }, isBroadcast: true);
  @override
  Future<LocalAudioSnapshot> snapshot() async {
    snapshotReads++;
    await snapshotGate?.future;
    return current;
  }

  @override
  Future<void> play(LocalAudioSource source) async {
    plays.add(source);
    await playGate?.future;
    if (playError != null) throw playError!;
  }

  @override
  Future<void> pause({String? expectedSourceId}) async {
    expectedSources.add(expectedSourceId);
    commands.add('pause');
  }

  @override
  Future<void> resume({String? expectedSourceId}) async {
    expectedSources.add(expectedSourceId);
    commands.add('resume');
  }

  @override
  Future<void> seek(Duration position, {String? expectedSourceId}) async {
    expectedSources.add(expectedSourceId);
    seeks.add(position);
  }

  @override
  Future<void> stop({String? expectedSourceId}) async {
    expectedSources.add(expectedSourceId);
    commands.add('stop');
    await stopGate?.future;
    if (stopError != null) throw stopError!;
  }

  @override
  Future<LocalAudioPowerStatus> readPowerStatus() async {
    powerReads++;
    await powerGate?.future;
    if (powerError != null) throw powerError!;
    return const LocalAudioPowerStatus(
      supported: true,
      sdkInt: 36,
      notificationsEnabled: false,
      notificationPermissionGranted: false,
      mediaNotificationExempt: true,
      batteryOptimizationExempt: false,
      backgroundRestricted: true,
    );
  }

  @override
  Future<bool> openBatterySettings() async {
    batteryOpens++;
    return settingsAvailable;
  }

  @override
  Future<bool> openNotificationSettings() async {
    notificationOpens++;
    return settingsAvailable;
  }
}
