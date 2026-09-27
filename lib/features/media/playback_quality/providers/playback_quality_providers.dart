import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/android_playback_capability_port.dart';

final androidPlaybackCapabilityPortProvider =
    Provider<AndroidPlaybackCapabilityPort>(
      (ref) => MethodChannelAndroidPlaybackCapabilityPort(),
    );
