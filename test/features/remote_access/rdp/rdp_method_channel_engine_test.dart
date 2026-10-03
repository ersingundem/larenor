import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import 'rdp_models_test.dart' show fixture, profile;

class ClipboardMethods extends MethodChannel {
  ClipboardMethods(this.onClipboard) : super('rdp-test-methods');
  final Future<void> Function(Uint8List) onClipboard;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'input' && (arguments as Map)['kind'] == 'channel') {
      await onClipboard(arguments['payload'] as Uint8List);
      return null;
    }
    return super.invokeMethod<T>(method, arguments);
  }
}

class AudioMethods extends MethodChannel {
  AudioMethods(this.onAudio) : super('rdp-test-methods');
  final Future<Object?> Function(Map) onAudio;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'audioObservation') {
      return await onAudio(arguments as Map) as T?;
    }
    return super.invokeMethod<T>(method, arguments);
  }
}

class MicrophoneMethods extends MethodChannel {
  MicrophoneMethods(this.onMicrophone) : super('rdp-test-methods');
  final Future<Object?> Function(Map) onMicrophone;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'microphoneObservation') {
      return await onMicrophone(arguments as Map) as T?;
    }
    return super.invokeMethod<T>(method, arguments);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('rdp-test-methods');
  const events = EventChannel('rdp-test-events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => fixture()['availableCapabilities'],
        'inspect' => {
          'tls': true,
          'requiresNla': true,
          'certificateFingerprint':
              'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        },
        'open' => {
          'schemaVersion': 4,
          'unicodeTextInput': true,
          'relativePointer': true,
        },
        'requestMicrophonePermission' => {
          'schemaVersion': 4,
          'requestId': (call.arguments as Map)['requestId'],
          'granted': true,
        },
        'microphoneObservation' => {
          'schemaVersion': 4,
          'requestId': (call.arguments as Map)['requestId'],
          'state': 'pending',
          'deviceOpen': false,
          'capturedCount': 0,
          'acceptedCount': 0,
        },
        'cancelMicrophonePermission' => null,
        'selectFileTransferTree' => {
          'schemaVersion': 5,
          'requestId': (call.arguments as Map)['requestId'],
          'authorityId': RdpSecurityStore()
              .fileTransferAuthority(profile, profileRevision: 9)
              .authorityId,
          'grantId': '0123456789abcdef0123456789abcdef',
          'grantRevision': 3,
          'state': 'prepared',
        },
        'activateFileTransferGrant' => {
          'schemaVersion': 5,
          'requestId': (call.arguments as Map)['requestId'],
          'authorityId': RdpSecurityStore()
              .fileTransferAuthority(profile, profileRevision: 9)
              .authorityId,
          'grantId': (call.arguments as Map)['grantId'],
          'grantRevision': (call.arguments as Map)['expectedGrantRevision'],
          'state': 'active',
        },
        'fileTransferGrantObservation' => {
          'schemaVersion': 5,
          'requestId': (call.arguments as Map)['requestId'],
          'authorityId': RdpSecurityStore()
              .fileTransferAuthority(profile, profileRevision: 9)
              .authorityId,
          'grantId': (call.arguments as Map)['grantId'],
          'grantRevision': (call.arguments as Map)['expectedGrantRevision'],
          'state': 'active',
        },
        'retireFileTransferGrant' => {
          'schemaVersion': 5,
          'requestId': (call.arguments as Map)['requestId'],
          'authorityId': RdpSecurityStore()
              .fileTransferAuthority(profile, profileRevision: 9)
              .authorityId,
          'grantId': (call.arguments as Map)['grantId'],
          'grantRevision': (call.arguments as Map)['expectedGrantRevision'],
          'state': 'retired',
        },
        'cancelFileTransferTree' => null,
        'activate' || 'input' || 'resize' || 'ackFrame' || 'cancel' => null,
        _ => throw MissingPluginException(),
      };
    });
    messenger.setMockMessageHandler(events.name, (message) async {
      final call = const StandardMethodCodec().decodeMethodCall(message);
      expect(call.method, anyOf('listen', 'cancel'));
      return const StandardMethodCodec().encodeSuccessEnvelope(null);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMessageHandler(events.name, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<RdpChannel> openClipboard(
    RdpMethodChannelEngine engine, {
    bool Function()? current,
    bool enabled = true,
    bool audio = false,
    bool microphone = false,
  }) => engine.open(
    RdpSessionRequest(
      profile: profile,
      display: const RdpDisplaySpec(
        width: 640,
        height: 480,
        desktopScaleFactor: 160,
      ),
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      settings: RdpProfileSettings(
        clipboardMode: enabled
            ? RdpClipboardMode.clientToRemote
            : RdpClipboardMode.disabled,
        microphone: microphone,
      ),
      channels: RdpChannelPolicy(
        clipboard: enabled,
        audio: audio,
        microphone: microphone,
      ),
    ),
    credential: const RdpCredential(password: 'temporary'),
    isCurrent: current ?? () => true,
  );

  Future<RdpChannel> openMicrophone(RdpMethodChannelEngine engine) async {
    expect(
      await engine.requestMicrophonePermission(isCurrent: () => true),
      isTrue,
    );
    return openClipboard(engine, microphone: true);
  }

  RdpFileTransferAuthority transferAuthority() =>
      RdpSecurityStore().fileTransferAuthority(profile, profileRevision: 9);

  test(
    'SAF picker and lifecycle receipts bind exact opaque authority',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final authority = transferAuthority();
      final prepared = await engine.selectFileTransferTree(
        authority: authority,
        isCurrent: () => true,
      );
      expect(prepared.state, RdpFileTransferGrantState.prepared);
      expect(prepared.authorityId, authority.authorityId);
      final select = calls.singleWhere(
        (call) => call.method == 'selectFileTransferTree',
      );
      expect(select.arguments, {
        'schemaVersion': 5,
        'requestId': (select.arguments as Map)['requestId'],
        'authority': authority.toWire(),
      });

      final active = await engine.activateFileTransferGrant(
        authority: authority,
        grant: prepared.grant,
        isCurrent: () => true,
      );
      expect(active.state, RdpFileTransferGrantState.active);
      expect(
        await engine.fileTransferGrantObservation(
          authority: authority,
          grant: prepared.grant,
          isCurrent: () => true,
        ),
        active,
      );
      final retired = await engine.retireFileTransferGrant(
        authority: authority,
        grant: prepared.grant,
      );
      expect(retired.state, RdpFileTransferGrantState.retired);
      for (final call in calls.where(
        (call) => const {
          'activateFileTransferGrant',
          'fileTransferGrantObservation',
          'retireFileTransferGrant',
        }.contains(call.method),
      )) {
        final body = call.arguments as Map;
        expect(body['schemaVersion'], 5);
        expect(body['authority'], authority.toWire());
        expect(body['grantId'], prepared.grant.id);
        expect(body['expectedGrantRevision'], prepared.grant.revision);
        expect(body.keys, {
          'schemaVersion',
          'requestId',
          'authority',
          'grantId',
          'expectedGrantRevision',
        });
      }
      engine.close();
    },
  );

  test(
    'retired picker result is fenced and exact prepared grant is retired',
    () async {
      var current = true;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'selectFileTransferTree') {
          current = false;
          return {
            'schemaVersion': 5,
            'requestId': (call.arguments as Map)['requestId'],
            'authorityId': transferAuthority().authorityId,
            'grantId': '0123456789abcdef0123456789abcdef',
            'grantRevision': 3,
            'state': 'prepared',
          };
        }
        if (call.method == 'retireFileTransferGrant') {
          return {
            'schemaVersion': 5,
            'requestId': (call.arguments as Map)['requestId'],
            'authorityId': transferAuthority().authorityId,
            'grantId': (call.arguments as Map)['grantId'],
            'grantRevision': (call.arguments as Map)['expectedGrantRevision'],
            'state': 'retired',
          };
        }
        if (call.method == 'cancelFileTransferTree') return null;
        throw MissingPluginException();
      });
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      await expectLater(
        engine.selectFileTransferTree(
          authority: transferAuthority(),
          isCurrent: () => current,
        ),
        throwsA(isA<RdpFailure>()),
      );
      expect(
        calls.where((call) => call.method == 'activateFileTransferGrant'),
        isEmpty,
      );
      expect(
        calls.where((call) => call.method == 'retireFileTransferGrant'),
        hasLength(1),
      );
      engine.close();
    },
  );

  test('SAF retirement keeps an unknown release outcome observable', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'retireFileTransferGrant') {
        return {
          'schemaVersion': 5,
          'requestId': (call.arguments as Map)['requestId'],
          'authorityId': transferAuthority().authorityId,
          'grantId': (call.arguments as Map)['grantId'],
          'grantRevision': (call.arguments as Map)['expectedGrantRevision'],
          'state': 'unknown',
        };
      }
      throw MissingPluginException();
    });
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final outcome = await engine.retireFileTransferGrant(
      authority: transferAuthority(),
      grant: const RdpFileTransferGrant(
        id: '0123456789abcdef0123456789abcdef',
        revision: 3,
      ),
    );
    expect(outcome.state, RdpFileTransferGrantState.unknown);
    engine.close();
  });

  test(
    'SAF response cannot expose raw provider fields or foreign identity',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'selectFileTransferTree') {
          return {
            'schemaVersion': 5,
            'requestId': (call.arguments as Map)['requestId'],
            'authorityId': 'f' * 64,
            'grantId': '0123456789abcdef0123456789abcdef',
            'grantRevision': 3,
            'state': 'prepared',
            'treeUri': 'content://must-not-cross',
          };
        }
        if (call.method == 'cancelFileTransferTree') return null;
        throw MissingPluginException();
      });
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      await expectLater(
        engine.selectFileTransferTree(
          authority: transferAuthority(),
          isCurrent: () => true,
        ),
        throwsA(isA<RdpFailure>()),
      );
      engine.close();
    },
  );

  test(
    'microphone permission receipt binds the exact session and observation',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openMicrophone(engine);
      final permission = calls.singleWhere(
        (value) => value.method == 'requestMicrophonePermission',
      );
      final open = calls.singleWhere((value) => value.method == 'open');
      final permissionId = (permission.arguments as Map)['requestId'];
      expect(permission.arguments, {
        'schemaVersion': 4,
        'requestId': permissionId,
      });
      expect((open.arguments as Map)['requestId'], permissionId);
      expect(((open.arguments as Map)['request'] as Map)['microphone'], isTrue);
      final observation = await (channel as RdpMicrophoneCaptureChannel)
          .microphoneObservation();
      expect(observation.state, RdpMicrophoneState.pending);
      expect(observation.hasSubmittedAudio, isFalse);
      expect(
        (calls
                .singleWhere((value) => value.method == 'microphoneObservation')
                .arguments
            as Map),
        {'schemaVersion': 4, 'requestId': permissionId},
      );
      channel.close();
    },
  );

  test('microphone disabled performs no permission request or query', () async {
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final channel = await openClipboard(engine);
    await expectLater(
      (channel as RdpMicrophoneCaptureChannel).microphoneObservation(),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      calls.where(
        (value) =>
            value.method == 'requestMicrophonePermission' ||
            value.method == 'microphoneObservation',
      ),
      isEmpty,
    );
    channel.close();
  });

  test('denied or retired permission cannot activate and exact cancellation is sent', () async {
    var current = true;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'requestMicrophonePermission') {
        current = false;
        return {
          'schemaVersion': 4,
          'requestId': (call.arguments as Map)['requestId'],
          'granted': true,
        };
      }
      if (call.method == 'cancelMicrophonePermission') return null;
      throw MissingPluginException();
    });
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    await expectLater(
      engine.requestMicrophonePermission(isCurrent: () => current),
      throwsA(isA<RdpFailure>()),
    );
    expect(calls.where((value) => value.method == 'activate'), isEmpty);
    final request = calls.first.arguments as Map;
    expect(calls.last.arguments, {
      'schemaVersion': 4,
      'requestId': request['requestId'],
    });
    expect(calls.last.method, 'cancelMicrophonePermission');
    engine.close();
  });

  test('closing a stuck microphone query cancels its deadline', () {
    fakeAsync((clock) {
      final native = Completer<Object?>();
      final engine = RdpMethodChannelEngine(
        methods: MicrophoneMethods((_) => native.future),
        events: events,
        isAndroid: true,
      );
      RdpMicrophoneCaptureChannel? channel;
      unawaited(
        openMicrophone(engine).then((value) {
          channel = value as RdpMicrophoneCaptureChannel;
        }),
      );
      clock.flushMicrotasks();
      var retired = false;
      unawaited(
        channel!.microphoneObservation().then<void>(
          (_) => fail('late microphone observation'),
          onError: (Object error) {
            retired = error is RdpFailure;
          },
        ),
      );
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 1);
      channel!.close();
      clock.flushMicrotasks();
      expect(retired, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
      native.complete({
        'schemaVersion': 4,
        'requestId': 'late',
        'state': 'sent',
        'deviceOpen': true,
        'capturedCount': 1,
        'acceptedCount': 1,
      });
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('audio readback binds exact request, serializes reads and requires completion', () async {
    var reads = 0;
    Map? arguments;
    final reply = Completer<Object?>();
    final engine = RdpMethodChannelEngine(
      methods: AudioMethods((value) {
        reads++;
        arguments = value;
        return reply.future;
      }),
      events: events,
    );
    final channel =
        await openClipboard(engine, audio: true) as RdpAudioPlaybackChannel;
    final first = channel.audioObservation(),
        second = channel.audioObservation();
    await Future<void>.delayed(Duration.zero);
    final id =
        (calls.singleWhere((v) => v.method == 'open').arguments
            as Map)['requestId'];
    expect(arguments, {'schemaVersion': 4, 'requestId': id});
    expect(reads, 1);
    reply.complete({
      'schemaVersion': 4,
      'requestId': id,
      'state': 'playing',
      'deviceOpen': true,
      'acceptedCount': 1,
      'completedCount': 0,
    });
    expect((await first).hasCompletedPlayback, isFalse);
    expect(await second, await first);
    expect(calls.where((v) => v.method == 'input'), isEmpty);
    channel.close();
  });

  test('audio off has zero query and stale or foreign audio cannot become evidence', () async {
    var reads = 0, current = true;
    final reply = Completer<Object?>();
    final methodsWithAudio = AudioMethods((value) {
      reads++;
      return reply.future;
    });
    final offEngine = RdpMethodChannelEngine(
      methods: methodsWithAudio,
      events: events,
    );
    final off = await openClipboard(offEngine) as RdpAudioPlaybackChannel;
    await expectLater(off.audioObservation(), throwsA(isA<RdpFailure>()));
    expect(reads, 0);
    off.close();
    final engine = RdpMethodChannelEngine(
      methods: methodsWithAudio,
      events: events,
    );
    final channel = await openClipboard(
      engine,
      audio: true,
      current: () => current,
    ) as RdpAudioPlaybackChannel;
    final awaiting = channel.audioObservation();
    final rejected = expectLater(awaiting, throwsA(isA<RdpFailure>()));
    current = false;
    reply.complete({
      'schemaVersion': 4,
      'requestId': 'foreign',
      'state': 'playing',
      'deviceOpen': true,
      'acceptedCount': 1,
      'completedCount': 1,
    });
    await rejected;
    expect(reads, 1);
    await channel.done;
  });

  test('audio counter rollback fails closed without an audio effect', () async {
    var reads = 0;
    final engine = RdpMethodChannelEngine(
      methods: AudioMethods(
        (value) async => {
          'schemaVersion': 4,
          'requestId': value['requestId'],
          'state': 'playing',
          'deviceOpen': true,
          'acceptedCount': 2,
          'completedCount': reads++ == 0 ? 2 : 1,
        },
      ),
      events: events,
    );
    final channel =
        await openClipboard(engine, audio: true) as RdpAudioPlaybackChannel;
    expect((await channel.audioObservation()).hasCompletedPlayback, isTrue);
    await expectLater(channel.audioObservation(), throwsA(isA<RdpFailure>()));
    await channel.done;
    expect(calls.where((v) => v.method == 'input'), isEmpty);
  });

  test(
    'closing a stuck audio query cancels its owned deadline and late reply',
    () {
      fakeAsync((clock) {
        final native = Completer<Object?>();
        final engine = RdpMethodChannelEngine(
          methods: AudioMethods((_) => native.future),
          events: events,
        );
        RdpAudioPlaybackChannel? channel;
        unawaited(
          openClipboard(engine, audio: true).then((value) {
            channel = value as RdpAudioPlaybackChannel;
          }),
        );
        clock.flushMicrotasks();
        expect(channel, isNotNull);
        var retired = false;
        unawaited(
          channel!.audioObservation().then<void>(
            (_) => fail('late playback'),
            onError: (Object error) {
              retired = error is RdpFailure;
            },
          ),
        );
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 1);
        channel!.close();
        clock.flushMicrotasks();
        expect(retired, isTrue);
        expect(clock.nonPeriodicTimerCount, 0);
        native.complete({
          'schemaVersion': 4,
          'requestId': 'stale',
          'state': 'playing',
          'deviceOpen': true,
          'acceptedCount': 1,
          'completedCount': 1,
        });
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  Future<RdpFrame> deliverFrame(
    RdpFrameChannel channel, {
    int sequence = 1,
    int revision = 1,
    int width = 640,
    int height = 480,
    bool acknowledge = true,
  }) async {
    final requestId =
        (calls.lastWhere((call) => call.method == 'open').arguments
            as Map)['requestId'];
    final awaiting = channel.frames.first;
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'requestId': requestId,
        'kind': 'frame',
        'payload': {
          'schemaVersion': 4,
          'sequence': sequence,
          'width': width,
          'height': height,
          'stride': width * 4,
          'displayLayoutRevision': revision,
          'pixels': Uint8List(width * height * 4),
        },
      }),
      (_) {},
    );
    final frame = await awaiting;
    if (acknowledge) {
      expect(await channel.acknowledgeFrame(frame.sequence), isTrue);
    }
    return frame;
  }

  test(
    'clipboard uses typed UTF-8 channel input and shared ordered sequence',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine);
      channel.key(const RdpKeyEvent(physicalKey: 0x00070004, down: true));
      expect(await channel.sendClipboardText('İstanbul\n😀'), isTrue);
      channel.text('composed');
      await Future<void>.delayed(Duration.zero);
      final inputs = calls.where((c) => c.method == 'input').toList();
      expect(inputs.map((c) => (c.arguments as Map)['sequence']), [1, 2, 3]);
      final clipboard = inputs[1].arguments as Map;
      expect(clipboard.keys.toSet(), {
        'schemaVersion',
        'requestId',
        'sequence',
        'kind',
        'channel',
        'payload',
      });
      expect(clipboard['kind'], 'channel');
      expect(clipboard['channel'], 'clipboard');
      expect(clipboard['payload'], isA<Uint8List>());
      expect(utf8.decode(clipboard['payload'] as Uint8List), 'İstanbul\n😀');
      expect(
        clipboard['requestId'],
        (calls.singleWhere((c) => c.method == 'open').arguments
            as Map)['requestId'],
      );
      for (final value in ['', 'bad\u0000text', '\ud800', '😀' * 16385]) {
        expect(await channel.sendClipboardText(value), isFalse);
      }
      expect(calls.where((c) => c.method == 'input'), hasLength(3));
      channel.close();
      engine.close();
    },
  );

  test(
    'clipboard opt-out or stale authority never dispatches native input',
    () async {
      var current = true;
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final off = await openClipboard(engine, enabled: false);
      expect(await off.sendClipboardText('private'), isFalse);
      off.close();
      final on = await openClipboard(engine, current: () => current);
      current = false;
      expect(await on.sendClipboardText('private'), isFalse);
      expect(calls.where((c) => c.method == 'input'), isEmpty);
      on.close();
      engine.close();
    },
  );

  for (final failure in [false, true]) {
    test(
      'clipboard zeroes original payload after ${failure ? 'native failure' : 'late authority retirement'}',
      () async {
        Uint8List? original;
        var current = true;
        final reply = Completer<void>();
        final direct = ClipboardMethods((bytes) async {
          original = bytes;
          expect(utf8.decode(bytes), 'private');
          await reply.future;
          if (failure) throw PlatformException(code: 'invalidRequest');
        });
        final engine = RdpMethodChannelEngine(
          methods: direct,
          events: events,
          isAndroid: true,
        );
        final channel = await openClipboard(engine, current: () => current);
        final pending = channel.sendClipboardText('private');
        await Future<void>.delayed(Duration.zero);
        if (!failure) current = false;
        reply.complete();
        expect(await pending, isFalse);
        expect(original, isNotNull);
        expect(original, everyElement(0));
        channel.close();
        engine.close();
      },
    );
  }

  test(
    'lost native clipboard reply closes exact channel and wipes bytes',
    () async {
      Uint8List? original;
      final reply = Completer<void>();
      final direct = ClipboardMethods((bytes) async {
        original = bytes;
        await reply.future;
      });
      final engine = RdpMethodChannelEngine(
        methods: direct,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine);
      fakeAsync((async) {
        bool? accepted;
        channel
            .sendClipboardText('private')
            .then((result) => accepted = result);
        async.flushMicrotasks();
        expect(original, isNotNull);
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(accepted, isFalse);
        expect(original, everyElement(0));
        reply.complete();
        async.flushMicrotasks();
        expect(accepted, isFalse);
      });
      expect(await channel.sendClipboardText('no-replay'), isFalse);
      expect(calls.where((c) => c.method == 'cancel'), hasLength(1));
      engine.close();
    },
  );

  test(
    'false key reply is nonfatal but false pointer reply retires channel',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine);
      final frame = await deliverFrame(channel as RdpFrameChannel);
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return call.method == 'input' ? false : null;
      });
      channel.key(const RdpKeyEvent(physicalKey: 0x00070004, down: true));
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      channel.pointer(
        RdpPointerEvent(x: 1, y: 1, buttons: 0, geometry: frame.geometry),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      channel.key(const RdpKeyEvent(physicalKey: 0x00070004, down: false));
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'input'), hasLength(2));
      engine.close();
    },
  );

  test('verified native capability and probe stay exact and scoped', () async {
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final capabilities = await engine.capabilities(isCurrent: () => true);
    expect(capabilities.canConnect, isTrue);
    final probe = await engine.inspect(profile, isCurrent: () => true);
    expect(probe.tlsCertificateObserved, isTrue);
    expect(probe.clientRequiresNla, isTrue);
    expect(probe.certificate.algorithm, 'spki-sha256');
    expect(calls[1].arguments, {
      'targetHost': profile.host,
      'targetPort': profile.port,
      'username': profile.username,
    });
    engine.close();
  });

  test(
    'open forwards locked policy and one bounded frame acknowledgement',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final request = RdpSessionRequest(
        profile: profile,
        display: const RdpDisplaySpec(
          width: 640,
          height: 480,
          desktopScaleFactor: 160,
        ),
        certificateFingerprint:
            'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        settings: const RdpProfileSettings(
          clipboardMode: RdpClipboardMode.clientToRemote,
        ),
        channels: const RdpChannelPolicy(clipboard: true),
      );
      final opened = await engine.open(
        request,
        credential: const RdpCredential(password: 'temporary'),
        isCurrent: () => true,
      );
      expect(
        (opened as RdpNegotiatedInputChannel).supportsUnicodeInput,
        isTrue,
      );
      final open = calls.singleWhere((call) => call.method == 'open');
      final arguments = open.arguments as Map;
      final native = arguments['request'] as Map;
      expect(native['requiresNla'], isTrue);
      expect(native['clipboardMode'], 'clientToRemote');
      expect(native['audio'], isFalse);
      expect(native['files'], isFalse);
      expect(arguments['password'], isA<Uint8List>());
      expect(arguments.values, isNot(contains('temporary')));

      final channel = opened as RdpFrameChannel;
      channel.text('İstanbul');
      await Future<void>.delayed(Duration.zero);
      final ime = calls.singleWhere(
        (call) =>
            call.method == 'input' && (call.arguments as Map)['kind'] == 'ime',
      );
      expect(ime.arguments, {
        'schemaVersion': 4,
        'requestId': arguments['requestId'],
        'sequence': 1,
        'kind': 'ime',
        'text': 'İstanbul',
      });
      channel.text('');
      channel.text('x' * 4097);
      channel.text('\ud800');
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where(
          (call) =>
              call.method == 'input' &&
              (call.arguments as Map)['kind'] == 'ime',
        ),
        hasLength(1),
      );
      final frameFuture = channel.frames.first;
      final requestId = arguments['requestId'] as String;
      final pixels = Uint8List(640 * 480 * 4);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'requestId': requestId,
          'kind': 'frame',
          'payload': {
            'sequence': 1,
            'width': 640,
            'height': 480,
            'stride': 2560,
            'schemaVersion': 4,
            'displayLayoutRevision': 1,
            'pixels': pixels,
          },
        }),
        (_) {},
      );
      final frame = await frameFuture;
      expect(frame.bgra, hasLength(pixels.length));
      await channel.acknowledgeFrame(frame.sequence);
      expect(calls.where((call) => call.method == 'ackFrame'), hasLength(1));
      channel.close();
    },
  );
  test('first native frame is retained before the UI subscribes', () async {
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final channel = await openClipboard(engine) as RdpFrameChannel;
    final id =
        (calls.lastWhere((c) => c.method == 'open').arguments
            as Map)['requestId'];
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'requestId': id,
        'kind': 'frame',
        'payload': {
          'schemaVersion': 4,
          'sequence': 1,
          'width': 640,
          'height': 480,
          'stride': 2560,
          'displayLayoutRevision': 1,
          'pixels': Uint8List(640 * 480 * 4),
        },
      }),
      (_) {},
    );
    final frame = await channel.frames.first;
    expect(frame.sequence, 1);
    expect(await channel.acknowledgeFrame(1), isTrue);
    expect(await channel.acknowledgeFrame(1), isFalse);
    expect(calls.where((c) => c.method == 'ackFrame'), hasLength(1));
    channel.close();
    engine.close();
  });

  test(
    'unACKed frames preserve displayed geometry; a new ACK replaces it',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine) as RdpFrameChannel;
      final first = await deliverFrame(channel);
      final next = await deliverFrame(channel, sequence: 2, acknowledge: false);
      channel.pointer(
        RdpPointerEvent(x: .2, y: .3, buttons: 0, geometry: first.geometry),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'input'), hasLength(1));
      expect(await channel.acknowledgeFrame(next.sequence), isTrue);
      channel.pointer(
        RdpPointerEvent(x: .2, y: .3, buttons: 0, geometry: first.geometry),
      );
      channel.relativePointer(
        RdpRelativePointerEvent(
          deltaX: -2,
          deltaY: 3,
          buttons: 1,
          geometry: next.geometry,
        ),
      );
      channel.wheel(RdpWheelEvent(wheelDelta: -120, geometry: next.geometry));
      await Future<void>.delayed(Duration.zero);
      final input = calls
          .where((c) => c.method == 'input')
          .map((c) => c.arguments as Map)
          .toList();
      expect(input.map((m) => m['kind']), [
        'absolutePointer',
        'relativePointer',
        'verticalWheel',
      ]);
      expect(input.map((m) => m['sequence']), [1, 2, 3]);
      expect(input.last['frameSequence'], 2);
      expect(input.last['displayLayoutRevision'], 1);
      expect(input[1]['deltaX'], -2);
      expect(input.last['wheelDelta'], -120);
      channel.close();
      engine.close();
    },
  );

  test(
    'same-size density resize blocks input until the matching new layout ACK',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine) as RdpFrameChannel;
      final first = await deliverFrame(channel);
      channel.resize(
        const RdpDisplaySpec(
          width: 640,
          height: 480,
          desktopScaleFactor: 200,
          deviceScaleFactor: 180,
        ),
      );
      channel.pointer(
        RdpPointerEvent(x: .5, y: .5, buttons: 0, geometry: first.geometry),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'input'), isEmpty);
      final transitional = await deliverFrame(channel, sequence: 2);
      channel.pointer(
        RdpPointerEvent(
          x: .5,
          y: .5,
          buttons: 0,
          geometry: transitional.geometry,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'input'), isEmpty);
      final current = await deliverFrame(channel, sequence: 3, revision: 2);
      channel.pointer(
        RdpPointerEvent(x: .5, y: .5, buttons: 0, geometry: current.geometry),
      );
      await Future<void>.delayed(Duration.zero);
      final input =
          calls.singleWhere((c) => c.method == 'input').arguments as Map;
      expect(input['sequence'], 2);
      final display =
          (calls.singleWhere((c) => c.method == 'resize').arguments
                  as Map)['display']
              as Map;
      expect(display['desktopScaleFactor'], 200);
      expect(display['deviceScaleFactor'], 180);
      expect(display.containsKey('dpi'), isFalse);
      channel.close();
      engine.close();
    },
  );

  test(
    'relative input requires the current authenticated peer negotiation',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'open') {
          return {
            'schemaVersion': 4,
            'unicodeTextInput': true,
            'relativePointer': false,
          };
        }
        return null;
      });
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine) as RdpFrameChannel;
      final frame = await deliverFrame(channel);
      expect(
        (channel as RdpNegotiatedInputChannel).supportsRelativePointer,
        isFalse,
      );
      channel.relativePointer(
        RdpRelativePointerEvent(
          deltaX: 1,
          deltaY: 1,
          buttons: 0,
          geometry: frame.geometry,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'input'), isEmpty);
      channel.close();
      engine.close();
    },
  );
}
