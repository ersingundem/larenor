import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_display_geometry.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import '../remote_profiles_ui_fixture.dart';
import '../core_personal_profiles_test_support.dart';
import 'rdp_models_test.dart' show fixture, packagedCapabilities;

const _defaultWindow = WindowPolicySnapshot(
  supported: true,
  isResumed: true,
  hasWindowFocus: true,
  displayId: 0,
  displayRevision: 1,
);

const _fullscreenWindow = WindowPolicySnapshot(
  supported: true,
  requestedProfile: WindowProfile.adaptive,
  effectiveMode: WindowEffectiveMode.panelRequested,
  reason: WindowRestrictionReason.none,
  isResumed: true,
  hasWindowFocus: true,
  displayId: 0,
  displayRevision: 1,
  captionVisible: false,
  imeVisible: false,
  statusBarVisible: true,
  navigationBarVisible: true,
);

Map<String, Object?> fullscreenWindowPacket() => {
  'supported': true,
  'requestedProfile': 'adaptive',
  'effectiveMode': 'panelRequested',
  'reason': 'none',
  'isResumed': true,
  'hasWindowFocus': true,
  'isMultiWindow': false,
  'isPictureInPicture': false,
  'isExternalDisplay': false,
  'displayId': 0,
  'displayRevision': 1,
  'captionVisible': false,
  'imeVisible': false,
  'statusBarVisible': true,
  'navigationBarVisible': true,
  'lockTaskPermitted': null,
  'lockTaskState': 'unknown',
};

WindowPolicySnapshot _externalWindow(int id, int revision) =>
    WindowPolicySnapshot(
      supported: true,
      isResumed: true,
      hasWindowFocus: true,
      isExternalDisplay: true,
      displayId: id,
      displayRevision: revision,
    );

class UiTrust implements RdpTrustStore {
  final pin = RdpCertificatePin.fromJson(fixture()['certificate']);
  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {}
  @override
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => pin;
  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) async {}
}

class UiChannel
    implements
        RdpChannel,
        RdpFrameChannel,
        RdpNegotiatedInputChannel,
        RdpAudioPlaybackChannel,
        RdpMicrophoneCaptureChannel {
  UiChannel({required this.supportsUnicodeInput}) {
    _frames = StreamController<RdpFrame>.broadcast(
      onListen: () {
        activeFrameListeners++;
        if (activeFrameListeners > maxFrameListeners) {
          maxFrameListeners = activeFrameListeners;
        }
      },
      onCancel: () => activeFrameListeners--,
    );
  }
  @override
  final bool supportsUnicodeInput;
  int audioReads = 0;
  String audioState = 'pending';
  int acceptedAudio = 0, completedAudio = 0;
  @override
  Future<RdpAudioObservation> audioObservation() async {
    audioReads++;
    return RdpAudioObservation.fromJson({
      'schemaVersion': 4,
      'requestId': 'ui-fixture',
      'state': audioState,
      'deviceOpen': audioState == 'deviceOpen' || audioState == 'playing',
      'acceptedCount': acceptedAudio,
      'completedCount': completedAudio,
    }, requestId: 'ui-fixture');
  }

  int microphoneReads = 0;
  String microphoneState = 'pending';
  int capturedMicrophone = 0, acceptedMicrophone = 0;
  @override
  Future<RdpMicrophoneObservation> microphoneObservation() async {
    microphoneReads++;
    return RdpMicrophoneObservation.fromJson({
      'schemaVersion': 4,
      'requestId': 'ui-fixture',
      'state': microphoneState,
      'deviceOpen': const {
        'opened',
        'captured',
        'sent',
      }.contains(microphoneState),
      'capturedCount': capturedMicrophone,
      'acceptedCount': acceptedMicrophone,
    }, requestId: 'ui-fixture');
  }

  @override
  bool get supportsRelativePointer => false;
  final doneCompleter = Completer<void>();
  final pointers = <RdpPointerEvent>[];
  final relativePointers = <RdpRelativePointerEvent>[];
  final wheels = <RdpWheelEvent>[];
  final keys = <RdpKeyEvent>[];
  final displays = <RdpDisplaySpec>[];
  final texts = <String>[];
  final clipboards = <String>[];
  final acknowledgements = <int>[];
  late final StreamController<RdpFrame> _frames;
  int activeFrameListeners = 0;
  int maxFrameListeners = 0;
  bool clipboardAccepted = true;
  bool acknowledgementAccepted = true;
  RdpDisplaySpec? currentDisplay;
  int displayLayoutRevision = 1;
  Completer<bool>? clipboardReply;
  @override
  Future<void> get done => doneCompleter.future;
  @override
  Stream<RdpFrame> get frames => _frames.stream;
  bool get hasFrameListener => _frames.hasListener;
  @override
  void close() {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  @override
  Future<bool> acknowledgeFrame(int sequence) async {
    acknowledgements.add(sequence);
    return acknowledgementAccepted;
  }

  void frame({int sequence = 1, int? width, int? height, int? layoutRevision}) {
    final display = currentDisplay;
    final frameWidth = width ?? display?.width ?? 960;
    final frameHeight = height ?? display?.height ?? 540;
    _frames.add(
      RdpFrame(
        sequence: sequence,
        width: frameWidth,
        height: frameHeight,
        displayLayoutRevision: layoutRevision ?? displayLayoutRevision,
        stride: frameWidth * 4,
        bgra: Uint8List(frameWidth * frameHeight * 4),
      ),
    );
  }

  @override
  void key(RdpKeyEvent event) => keys.add(event);
  @override
  void pointer(RdpPointerEvent event) => pointers.add(event);
  @override
  void relativePointer(RdpRelativePointerEvent event) =>
      relativePointers.add(event);
  @override
  void wheel(RdpWheelEvent event) => wheels.add(event);
  @override
  void resize(RdpDisplaySpec display) {
    displays.add(display);
    currentDisplay = display;
    displayLayoutRevision++;
  }

  @override
  void text(String value) => texts.add(value);
  @override
  Future<bool> sendClipboardText(String value) async {
    clipboards.add(value);
    return clipboardReply?.future ?? clipboardAccepted;
  }
}

class UiEngine
    implements RdpMicrophonePermissionEngine, RdpFileTransferGrantEngine {
  UiEngine({
    this.supportsIme = false,
    this.supportsResize = true,
    this.supportsAudio = false,
    this.supportsMicrophone = false,
  });
  final bool supportsIme;
  final bool supportsResize;
  final bool supportsAudio;
  final bool supportsMicrophone;
  bool permissionGranted = true;
  Completer<bool>? permissionReply;
  int permissionRequests = 0, permissionCancels = 0;
  int fileTransferSelections = 0,
      fileTransferActivations = 0,
      fileTransferObservations = 0,
      fileTransferRetirements = 0,
      fileTransferCancellations = 0;
  @override
  bool fileTransferPickerPending = false;
  RdpFileTransferAuthority? lastFileTransferAuthority;
  RdpFileTransferGrantState observedFileTransferState =
      RdpFileTransferGrantState.active;
  Completer<RdpFileTransferGrantObservation>? fileTransferSelectionReply;
  late final channel = UiChannel(supportsUnicodeInput: supportsIme);
  final requests = <RdpSessionRequest>[];
  int capabilityReads = 0;
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    capabilityReads++;
    final packet = packagedCapabilities(ime: supportsIme, audio: supportsAudio);
    (packet['channels']! as Map<String, Object?>)['microphone'] =
        supportsMicrophone;
    (packet['display']! as Map<String, Object?>)['dynamicResolution'] =
        supportsResize;
    return RdpCapabilities.fromJson(packet);
  }

  @override
  Future<RdpCertificateProbe> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => RdpCertificateProbe(
    tlsCertificateObserved: true,
    clientRequiresNla: true,
    certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
  );
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) async {
    if (credential == null) throw const RdpFailure('invalid_credential');
    requests.add(request);
    channel.currentDisplay = request.display;
    channel.displayLayoutRevision = 1;
    return channel;
  }

  @override
  void close() {}

  @override
  Future<bool> requestMicrophonePermission({
    required bool Function() isCurrent,
  }) async {
    permissionRequests++;
    final granted =
        await (permissionReply?.future ??
            Future<bool>.value(permissionGranted));
    if (!isCurrent()) throw const RdpFailure('retired');
    return granted;
  }

  @override
  void cancelMicrophonePermission() => permissionCancels++;

  RdpFileTransferGrantObservation _fileTransfer(
    RdpFileTransferAuthority authority,
    RdpFileTransferGrantState state, {
    RdpFileTransferGrant grant = const RdpFileTransferGrant(
      id: '0123456789abcdef0123456789abcdef',
      revision: 1,
    ),
  }) => RdpFileTransferGrantObservation(
    authorityId: authority.authorityId,
    grant: grant,
    state: state,
  );

  @override
  Future<RdpFileTransferGrantObservation> selectFileTransferTree({
    required RdpFileTransferAuthority authority,
    required bool Function() isCurrent,
  }) async {
    fileTransferSelections++;
    fileTransferPickerPending = true;
    lastFileTransferAuthority = authority;
    try {
      final result =
          await (fileTransferSelectionReply?.future ??
              Future.value(
                _fileTransfer(authority, RdpFileTransferGrantState.prepared),
              ));
      if (!isCurrent()) throw const RdpFailure('retired');
      return result;
    } finally {
      fileTransferPickerPending = false;
    }
  }

  @override
  Future<RdpFileTransferGrantObservation> activateFileTransferGrant({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required bool Function() isCurrent,
  }) async {
    fileTransferActivations++;
    if (!isCurrent()) throw const RdpFailure('retired');
    return _fileTransfer(
      authority,
      RdpFileTransferGrantState.active,
      grant: grant,
    );
  }

  @override
  Future<RdpFileTransferGrantObservation> fileTransferGrantObservation({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required bool Function() isCurrent,
  }) async {
    fileTransferObservations++;
    if (!isCurrent()) throw const RdpFailure('retired');
    return _fileTransfer(authority, observedFileTransferState, grant: grant);
  }

  @override
  Future<RdpFileTransferGrantObservation> retireFileTransferGrant({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
  }) async {
    fileTransferRetirements++;
    return _fileTransfer(
      authority,
      RdpFileTransferGrantState.retired,
      grant: grant,
    );
  }

  @override
  void cancelFileTransferTree() {
    fileTransferCancellations++;
    fileTransferPickerPending = false;
    final reply = fileTransferSelectionReply;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(const RdpFailure('retired'));
    }
  }
}

class HeldCapabilityEngine extends UiEngine {
  final release = Completer<void>();

  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    capabilityReads++;
    await release.future;
    return RdpCapabilities.fromJson(packagedCapabilities());
  }
}

Future<void> openRdp(WidgetTester tester, RemoteUi ui) async {
  ui.windows.add(_defaultWindow);
  await tester.pump();
  await ui.edit(tester, name: 'Office PC');
  await press(tester, 'remote-protocol-rdp');
  await ui.save(tester);
  await ui.openFirst(tester);
  await press(tester, 'remote-rdp-open');
}

Future<void> connectRdp(WidgetTester tester) async {
  await press(tester, 'rdp-check');
  if (key('rdp-password').evaluate().isNotEmpty) {
    await tester.enterText(key('rdp-password'), 'one-time-password');
    await press(tester, 'rdp-authenticate');
  }
}

Future<void> enableClipboard(WidgetTester tester) async {
  await connectRdp(tester);
  await press(tester, 'rdp-clipboard-clientToRemote');
  await press(tester, 'rdp-settings-save');
  await connectRdp(tester);
}

Future<void> selectDisplayMode(WidgetTester tester, RdpDisplayMode mode) async {
  await press(tester, 'rdp-display-${mode.name}');
  await press(tester, 'rdp-settings-save');
}

Future<void> showFrame(
  WidgetTester tester,
  UiChannel channel, {
  int sequence = 1,
  int? width,
  int? height,
  int? layoutRevision,
}) async {
  expect(channel.hasFrameListener, isTrue);
  channel.frame(
    sequence: sequence,
    width: width,
    height: height,
    layoutRevision: layoutRevision,
  );
  await tester.pump();
  await tester.runAsync(() async {
    for (
      var attempt = 0;
      attempt < 100 && !channel.acknowledgements.contains(sequence);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
  expect(channel.acknowledgements, contains(sequence));
}

void main() {
  testWidgets(
    'remote sound is explicit per profile and reports native completion only',
    (tester) async {
      final engine = UiEngine(supportsAudio: true), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      expect(
        tester.widget<CupertinoSwitch>(key('rdp-audio-enable')).value,
        isFalse,
      );
      await press(tester, 'rdp-audio-enable');
      await connectRdp(tester);
      expect(engine.requests.last.channels.audio, isTrue);
      expect(
        tester.widget<CupertinoSwitch>(key('rdp-audio-enable')).onChanged,
        isNull,
      );
      await tester.ensureVisible(key('rdp-audio-status'));
      await tester.pumpAndSettle();
      expect(find.text('Audio: Waiting for remote sound'), findsOneWidget);
      engine.channel.audioState = 'playing';
      engine.channel.acceptedAudio = 1;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Audio: Waiting for remote sound'), findsOneWidget);
      expect(find.text('Audio: Remote sound played'), findsNothing);
      engine.channel.completedAudio = 1;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Audio: Remote sound played'), findsOneWidget);
      final reads = engine.channel.audioReads;
      await press(tester, 'rdp-back');
      await tester.pump(const Duration(seconds: 6));
      expect(engine.channel.audioReads, reads);
      await press(tester, 'remote-rdp-open');
      expect(
        tester.widget<CupertinoSwitch>(key('rdp-audio-enable')).value,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'microphone opt-in persists and reports capture separately from submission',
    (tester) async {
      final engine = UiEngine(supportsMicrophone: true), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      expect(
        tester.widget<CupertinoSwitch>(key('rdp-microphone-enable')).value,
        isFalse,
      );
      await press(tester, 'rdp-microphone-enable');
      await press(tester, 'rdp-settings-save');
      await connectRdp(tester);
      expect(engine.permissionRequests, 1);
      expect(engine.requests.last.channels.microphone, isTrue);
      expect(engine.channel.microphoneReads, 1);
      await tester.ensureVisible(key('rdp-microphone-status'));
      await tester.pumpAndSettle();
      expect(
        find.text('Microphone enabled; waiting for the session'),
        findsOneWidget,
      );
      engine.channel.microphoneState = 'captured';
      engine.channel.capturedMicrophone = 1;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Microphone audio captured'), findsOneWidget);
      expect(
        find.text('Microphone audio sent to the remote channel'),
        findsNothing,
      );
      engine.channel.microphoneState = 'sent';
      engine.channel.capturedMicrophone = 2;
      engine.channel.acceptedMicrophone = 1;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        find.text('Microphone audio sent to the remote channel'),
        findsOneWidget,
      );
      await press(tester, 'rdp-back');
      await press(tester, 'remote-rdp-open');
      expect(
        tester.widget<CupertinoSwitch>(key('rdp-microphone-enable')).value,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'owned permission focus handoff waits, while real background retires',
    (tester) async {
      final permission = Completer<bool>();
      final engine = UiEngine(supportsMicrophone: true)
        ..permissionReply = permission;
      final remoteUi = RemoteUi();
      await remoteUi.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, remoteUi);
      await press(tester, 'rdp-microphone-enable');
      await press(tester, 'rdp-settings-save');
      await press(tester, 'rdp-check');
      expect(engine.permissionRequests, 1);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      permission.complete(true);
      await tester.pump();
      expect(engine.requests, isEmpty);
      expect(key('rdp-session-panel'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pumpAndSettle();
      expect(key('rdp-password'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(engine.requests, isEmpty);
      expect(engine.permissionCancels, greaterThanOrEqualTo(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Core-managed permission focus handoff waits without relaxing background',
    (tester) async {
      final permission = Completer<bool>();
      final engine = UiEngine(supportsMicrophone: true)
        ..permissionReply = permission;
      final core = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(protocol: 'rdp');
      await core.account.initialize();
      addTearDown(core.account.dispose);
      final remoteUi = RemoteUi();
      await remoteUi.mount(
        tester,
        width: 1280,
        serverAccount: core.account,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      remoteUi.windows.add(_defaultWindow);
      await tester.pump();
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-rdp-open-$profileId');
      await press(tester, 'rdp-microphone-enable');
      await press(tester, 'rdp-settings-save');
      await press(tester, 'rdp-check');
      expect(engine.permissionRequests, 1);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      permission.complete(true);
      await tester.pump();
      expect(engine.requests, isEmpty);
      expect(key('core-rdp-$profileId'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pumpAndSettle();
      expect(key('rdp-trust'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(engine.requests, isEmpty);
      expect(engine.permissionCancels, greaterThanOrEqualTo(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'owned SAF picker survives its external activity and stores only opaque receipt',
    (tester) async {
      final selection = Completer<RdpFileTransferGrantObservation>();
      final engine = UiEngine()..fileTransferSelectionReply = selection;
      final remoteUi = RemoteUi();
      await remoteUi.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, remoteUi);
      await press(tester, 'rdp-file-transfer-select');
      expect(engine.fileTransferSelections, 1);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(key('rdp-session-panel'), findsOneWidget);
      expect(engine.fileTransferCancellations, 0);

      final authority = engine.lastFileTransferAuthority!;
      selection.complete(
        RdpFileTransferGrantObservation(
          authorityId: authority.authorityId,
          grant: const RdpFileTransferGrant(
            id: '0123456789abcdef0123456789abcdef',
            revision: 1,
          ),
          state: RdpFileTransferGrantState.prepared,
        ),
      );
      await tester.pump();
      expect(engine.fileTransferActivations, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.fileTransferActivations, 1);
      expect(
        find.textContaining('Folder permission is verified.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This only prepares folder permission; RDP file sharing is not enabled yet.',
        ),
        findsOneWidget,
      );
      expect(remoteUi.values.values.join(), isNot(contains('content://')));
      await connectRdp(tester);
      expect(engine.requests.single.channels.files, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'interaction retirement cancels an owned SAF picker and relocks settings',
    (tester) async {
      final selection = Completer<RdpFileTransferGrantObservation>();
      final engine = UiEngine()..fileTransferSelectionReply = selection;
      final remoteUi = RemoteUi();
      await remoteUi.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, remoteUi);
      await press(tester, 'rdp-file-transfer-select');
      expect(engine.fileTransferSelections, 1);

      remoteUi.interaction.setActive(false);
      await tester.pumpAndSettle();

      expect(engine.fileTransferCancellations, greaterThanOrEqualTo(1));
      expect(key('rdp-session-panel'), findsNothing);
      expect(engine.fileTransferActivations, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('explicit removal retires before deleting the opaque receipt', (
    tester,
  ) async {
    final engine = UiEngine(), remoteUi = RemoteUi();
    await remoteUi.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, remoteUi);
    await press(tester, 'rdp-file-transfer-select');
    expect(engine.fileTransferActivations, 1);
    await press(tester, 'rdp-file-transfer-remove');
    expect(engine.fileTransferRetirements, 1);
    expect(
      find.textContaining('No transfer folder is selected.'),
      findsOneWidget,
    );
    expect(key('rdp-file-transfer-select'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  void useAndroidWindowChannel(
    Future<Object?> Function(MethodCall call) handler,
  ) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(WindowPolicyBridge.methodChannelName);
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  void freezeAndroidWindowBridge(WidgetTester tester) {
    ProviderScope.containerOf(
      tester.element(key('rdp-session-panel')),
      listen: false,
    ).read(windowPolicyBridgeProvider);
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets(
    'lost clipboard submission retires once and permits explicit reconnect',
    (tester) async {
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () {
          final e = UiEngine();
          engines.add(e);
          return e;
        },
        rdpTrust: UiTrust(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async =>
                call.method == 'Clipboard.getData' ? {'text': 'private'} : null,
          );
      await openRdp(tester, ui);
      await enableClipboard(tester);
      final old = engines.last.channel;
      old.clipboardReply = Completer<bool>();
      await tester.ensureVisible(key('rdp-clipboard-send'));
      await tester.pumpAndSettle();
      await tester.tap(key('rdp-clipboard-send'));
      await tester.pump();
      expect(old.clipboards, ['private']);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(old.doneCompleter.isCompleted, isTrue);
      expect(key('rdp-clipboard-send'), findsNothing);
      expect(find.textContaining('submitted to this session'), findsNothing);
      await press(tester, 'rdp-reconnect');
      await tester.enterText(key('rdp-password'), 'new-password');
      await press(tester, 'rdp-authenticate');
      expect(engines.last.channel, isNot(same(old)));
      old.clipboardReply!.complete(true);
      await tester.pumpAndSettle();
      expect(engines.last.channel.clipboards, isEmpty);
      await press(tester, 'rdp-clipboard-send');
      expect(engines.last.channel.clipboards, ['private']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in ['en', 'tr']) {
    testWidgets('$locale clipboard is explicit, scoped and accessible at 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: locale == 'en' ? 1280 : 600,
        scale: 2,
        locale: locale,
        rdpEngine: () {
          final engine = UiEngine();
          engines.add(engine);
          return engine;
        },
        rdpTrust: UiTrust(),
      );
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              expect(call.arguments, Clipboard.kTextPlain);
              return {'text': 'İstanbul\n😀'};
            }
            return null;
          });
      await openRdp(tester, ui);
      await enableClipboard(tester);
      expect(reads, 0);
      expect(engines.expand((e) => e.channel.clipboards), isEmpty);
      expect(
        tester.getSize(key('rdp-clipboard-send')).height,
        greaterThanOrEqualTo(48),
      );
      await press(tester, 'rdp-clipboard-send');
      expect(reads, 1);
      expect(engines.last.channel.clipboards, ['İstanbul\n😀']);
      expect(
        find.textContaining(
          locale == 'en' ? 'submitted to this session' : 'bu oturuma iletildi',
        ),
        findsOneWidget,
      );
      expect(ui.values.values, isNot(contains('İstanbul\n😀')));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets(
    'clipboard disabled never reads, and native refusal is not success',
    (tester) async {
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () {
          final e = UiEngine();
          engines.add(e);
          return e;
        },
        rdpTrust: UiTrust(),
      );
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return {'text': 'private'};
            }
            return null;
          });
      await openRdp(tester, ui);
      await connectRdp(tester);
      expect(key('rdp-clipboard-send'), findsNothing);
      expect(reads, 0);
      await press(tester, 'rdp-clipboard-clientToRemote');
      await press(tester, 'rdp-settings-save');
      await connectRdp(tester);
      engines.last.channel.clipboardAccepted = false;
      await press(tester, 'rdp-clipboard-send');
      expect(reads, 1);
      expect(find.textContaining('submitted to this session'), findsNothing);
      expect(
        find.textContaining('Check the session before trying again'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final timeout in [false, true]) {
    testWidgets(
      'pending clipboard ${timeout ? 'timeout' : 'foreground retirement'} never sends late data',
      (tester) async {
        final ui = RemoteUi(), engines = <UiEngine>[];
        await ui.mount(
          tester,
          width: 1280,
          rdpEngine: () {
            final e = UiEngine();
            engines.add(e);
            return e;
          },
          rdpTrust: UiTrust(),
        );
        final pending = Completer<Map<String, Object?>?>();
        var reads = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                reads++;
                return pending.future;
              }
              return null;
            });
        await openRdp(tester, ui);
        await enableClipboard(tester);
        await tester.ensureVisible(key('rdp-clipboard-send'));
        await tester.pumpAndSettle();
        await tester.tap(key('rdp-clipboard-send'));
        await tester.pump();
        expect(reads, 1);
        if (timeout) {
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Check the session before trying again'),
            findsOneWidget,
          );
        } else {
          ui.interaction.setActive(false);
          await tester.pumpAndSettle();
          expect(key('rdp-session-panel'), findsNothing);
        }
        pending.complete({'text': 'late-private'});
        await tester.pumpAndSettle();
        expect(engines.expand((e) => e.channel.clipboards), isEmpty);
        expect(find.textContaining('submitted to this session'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('tablet panel exposes unavailable native engine honestly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ui = RemoteUi();
    await ui.mount(tester, width: 1280, scale: 2);
    await openRdp(tester, ui);

    expect(find.byKey(const ValueKey('rdp-session-panel')), findsOneWidget);
    expect(find.text('Clipboard: Off'), findsOneWidget);
    expect(find.text('Audio: Off'), findsOneWidget);
    expect(find.text('Files: Off'), findsOneWidget);
    await connectRdp(tester);
    await tester.fling(key('rdp-scroll'), const Offset(0, 2000), 5000);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('native RDP engine is not packaged'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rdp-connect')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Turkish 2x panel closes when PIN or idle scope retires', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, width: 600, scale: 2, locale: 'tr');
    await openRdp(tester, ui);
    expect(find.text('Pano: Kapalı'), findsOneWidget);
    ui.interaction.setActive(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-session-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rdp-password')), findsNothing);
  });

  testWidgets(
    'personal gateway display keyboard and clipboard settings persist',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        scale: 2,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);

      await connectRdp(tester);

      await tester.enterText(key('rdp-settings-domain'), 'LARENOR');
      await tester.enterText(
        key('rdp-settings-gateway-host'),
        'gateway.home.arpa',
      );
      await tester.enterText(key('rdp-settings-gateway-port'), '443');
      await tester.enterText(key('rdp-settings-gateway-user'), 'gateway-user');
      await press(tester, 'rdp-keyboard-turkishQ');
      await press(tester, 'rdp-clipboard-clientToRemote');
      await press(tester, 'rdp-settings-save');
      expect(find.text('RDP settings saved.'), findsOneWidget);

      expect(
        tester.getSize(key('rdp-settings-save')).height,
        greaterThanOrEqualTo(48),
      );
      await press(tester, 'rdp-back');
      await press(tester, 'remote-rdp-open');
      expect(
        tester
            .widget<CupertinoTextField>(key('rdp-settings-domain'))
            .controller!
            .text,
        'LARENOR',
      );
      expect(
        tester
            .widget<CupertinoTextField>(key('rdp-settings-gateway-host'))
            .controller!
            .text,
        'gateway.home.arpa',
      );
      expect(find.textContaining('Turkish Q'), findsOneWidget);
      expect(find.text('Clipboard: Device to remote ✓'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final locale in ['en', 'tr']) {
    final width = locale == 'en' ? 1280.0 : 600.0;
    testWidgets('$locale composed text is accessible at 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = UiEngine(supportsIme: true), ui = RemoteUi();
      await ui.mount(
        tester,
        width: width,
        scale: 2,
        locale: locale,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await connectRdp(tester);
      await tester.ensureVisible(key('rdp-text-input'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          locale == 'tr'
              ? 'Uzak masaüstüne gönderilecek metin'
              : 'Type text for the remote desktop',
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(key('rdp-text-send')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.enterText(key('rdp-text-input'), 'İstanbul');
      await press(tester, 'rdp-text-send');
      expect(engine.channel.texts, ['İstanbul']);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('connected DeX surface forwards pointer keyboard and resize', (
    tester,
  ) async {
    final engine = UiEngine(supportsIme: true), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    await showFrame(tester, engine.channel);
    await tester.pumpAndSettle();
    expect(key('rdp-surface'), findsOneWidget);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    expect(key('rdp-frame-image'), findsOneWidget);
    await tester.tapAt(tester.getCenter(key('rdp-frame-image')));
    tester.widget<Focus>(key('rdp-surface')).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(engine.channel.pointers, isNotEmpty);
    expect(engine.channel.keys, hasLength(2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
    expect(engine.channel.keys, hasLength(2));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(key('rdp-frame-image')),
        scrollDelta: const Offset(0, 20),
      ),
    );
    expect(engine.channel.wheels, hasLength(1));
    expect(engine.channel.wheels.single.wheelDelta, -120);
    expect(
      engine.channel.wheels.single.geometry,
      engine.channel.pointers.last.geometry,
    );
    await tester.enterText(key('rdp-text-input'), 'İstanbul');
    await press(tester, 'rdp-text-send');
    expect(engine.channel.texts, ['İstanbul']);
    expect(
      tester.widget<CupertinoTextField>(key('rdp-text-input')).controller!.text,
      isEmpty,
    );
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(engine.channel.displays, isNotEmpty);
  });

  testWidgets('unacknowledged frame never replaces displayed geometry', (
    tester,
  ) async {
    final engine = UiEngine(supportsResize: false), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    await showFrame(tester, engine.channel);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final firstImage = tester.widget<RawImage>(key('rdp-frame-image')).image;
    await tester.tapAt(tester.getCenter(key('rdp-frame-image')));
    expect(engine.channel.pointers, hasLength(2));
    final admittedGeometry = engine.channel.pointers.last.geometry;
    engine.channel.pointers.clear();

    engine.channel.acknowledgementAccepted = false;
    await showFrame(tester, engine.channel, sequence: 2);
    expect(
      tester.widget<RawImage>(key('rdp-frame-image')).image,
      same(firstImage),
    );
    await tester.tapAt(tester.getCenter(key('rdp-frame-image')));
    expect(engine.channel.pointers, hasLength(2));
    expect(engine.channel.pointers.last.geometry, admittedGeometry);
  });

  testWidgets(
    'fullscreen reparents one live surface and Escape releases its exact lease',
    (tester) async {
      final calls = <MethodCall>[];
      useAndroidWindowChannel((call) async {
        calls.add(call);
        if (call.method == 'acquireFullscreen') {
          return {
            'schemaVersion': 1,
            'accepted': true,
            'revision': 7,
            'snapshot': fullscreenWindowPacket(),
          };
        }
        if (call.method == 'releaseFullscreen') return true;
        throw PlatformException(code: 'unexpected');
      });
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      freezeAndroidWindowBridge(tester);
      await connectRdp(tester);
      ui.windows.add(_fullscreenWindow);
      await tester.pumpAndSettle();
      await showFrame(tester, engine.channel);
      await tester.ensureVisible(key('rdp-surface'));
      await tester.pumpAndSettle();
      final inlineHeight = tester.getSize(key('rdp-surface')).height;

      await press(tester, 'rdp-fullscreen-enter');
      await tester.pumpAndSettle();
      expect(key('rdp-fullscreen-overlay'), findsOneWidget);
      expect(
        tester.getSize(key('rdp-surface')).height,
        greaterThan(inlineHeight),
      );
      expect(engine.channel.activeFrameListeners, 1);
      expect(engine.channel.maxFrameListeners, 1);
      expect(tester.getSize(key('rdp-fullscreen-exit')).height, 48);
      expect(
        tester.getSemantics(key('rdp-fullscreen-exit')).label,
        contains('Exit full screen'),
      );
      await showFrame(tester, engine.channel, sequence: 2);

      tester.widget<Focus>(key('rdp-surface')).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('rdp-fullscreen-overlay'), findsNothing);
      expect(key('rdp-fullscreen-enter'), findsOneWidget);
      expect(engine.channel.maxFrameListeners, 1);
      expect(engine.channel.keys, isEmpty);
      expect(calls.map((call) => call.method), [
        'acquireFullscreen',
        'releaseFullscreen',
      ]);
      final owner = (calls.first.arguments as Map)['owner'];
      expect(owner, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(calls.last.arguments, {'owner': owner, 'revision': 7});
      expect(calls.map((call) => call.method), isNot(contains('setProfile')));
    },
  );

  testWidgets('fullscreen denial is explicit and keeps the session connected', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    useAndroidWindowChannel((call) async {
      calls.add(call);
      return {
        'schemaVersion': 1,
        'accepted': false,
        'revision': null,
        'snapshot': fullscreenWindowPacket(),
      };
    });
    final engine = UiEngine(), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    freezeAndroidWindowBridge(tester);
    await connectRdp(tester);
    ui.windows.add(_fullscreenWindow);
    await tester.pumpAndSettle();
    await press(tester, 'rdp-fullscreen-enter');
    await tester.pumpAndSettle();
    expect(key('rdp-fullscreen-overlay'), findsNothing);
    expect(key('rdp-fullscreen-denied'), findsOneWidget);
    expect(key('rdp-disconnect'), findsOneWidget);
    expect(calls.map((call) => call.method), ['acquireFullscreen']);
    expect(find.textContaining('system bars are hidden'), findsNothing);
  });

  testWidgets(
    'late fullscreen grant is released after route ownership retires',
    (tester) async {
      final calls = <MethodCall>[];
      final grant = Completer<Object?>();
      useAndroidWindowChannel((call) async {
        calls.add(call);
        if (call.method == 'acquireFullscreen') return grant.future;
        if (call.method == 'releaseFullscreen') return true;
        throw PlatformException(code: 'unexpected');
      });
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      freezeAndroidWindowBridge(tester);
      await connectRdp(tester);
      ui.windows.add(_fullscreenWindow);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('rdp-fullscreen-enter'));
      await tester.pumpAndSettle();
      await tester.tap(key('rdp-fullscreen-enter'));
      await tester.pump();
      expect(key('rdp-fullscreen-progress'), findsOneWidget);

      ui.interaction.setActive(false);
      await tester.pumpAndSettle();
      expect(key('rdp-session-panel'), findsNothing);
      grant.complete({
        'schemaVersion': 1,
        'accepted': true,
        'revision': 9,
        'snapshot': fullscreenWindowPacket(),
      });
      await tester.pumpAndSettle();
      expect(key('rdp-fullscreen-overlay'), findsNothing);
      expect(calls.map((call) => call.method), [
        'acquireFullscreen',
        'releaseFullscreen',
      ]);
      final owner = (calls.first.arguments as Map)['owner'];
      expect(calls.last.arguments, {'owner': owner, 'revision': 9});
    },
  );

  for (final sessionEnds in [false, true]) {
    testWidgets(
      'active fullscreen releases on ${sessionEnds ? 'session termination' : 'display replacement'}',
      (tester) async {
        final calls = <MethodCall>[];
        useAndroidWindowChannel((call) async {
          calls.add(call);
          if (call.method == 'acquireFullscreen') {
            return {
              'schemaVersion': 1,
              'accepted': true,
              'revision': 11,
              'snapshot': fullscreenWindowPacket(),
            };
          }
          if (call.method == 'releaseFullscreen') return true;
          throw PlatformException(code: 'unexpected');
        });
        final engine = UiEngine(), ui = RemoteUi();
        await ui.mount(
          tester,
          width: 1280,
          rdpEngine: () => engine,
          rdpTrust: UiTrust(),
        );
        await openRdp(tester, ui);
        freezeAndroidWindowBridge(tester);
        await connectRdp(tester);
        ui.windows.add(_fullscreenWindow);
        await tester.pumpAndSettle();
        await press(tester, 'rdp-fullscreen-enter');
        await tester.pumpAndSettle();
        expect(key('rdp-fullscreen-overlay'), findsOneWidget);
        if (sessionEnds) {
          engine.channel.doneCompleter.complete();
        } else {
          ui.windows.add(_externalWindow(2, 2));
        }
        await tester.pumpAndSettle();
        expect(key('rdp-fullscreen-overlay'), findsNothing);
        expect(calls.map((call) => call.method), [
          'acquireFullscreen',
          'releaseFullscreen',
        ]);
        final owner = (calls.first.arguments as Map)['owner'];
        expect(calls.last.arguments, {'owner': owner, 'revision': 11});
      },
    );
  }

  testWidgets('fit letterboxes actual frame and rejects hidden coordinates', (
    tester,
  ) async {
    final engine = UiEngine(supportsResize: false), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    await showFrame(tester, engine.channel);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    final surface = tester.getRect(key('rdp-surface'));
    final frame = tester.getRect(key('rdp-frame-image'));
    final source = engine.channel.currentDisplay!;
    expect(
      frame.width / frame.height,
      closeTo(source.width / source.height, .001),
    );
    expect(frame.width, lessThanOrEqualTo(surface.width));
    expect(frame.height, lessThanOrEqualTo(surface.height));

    final hidden = frame.left > surface.left
        ? Offset(surface.left + 1, surface.center.dy)
        : Offset(surface.center.dx, surface.top + 1);
    await tester.tapAt(hidden);
    expect(engine.channel.pointers, isEmpty);
    await tester.tapAt(frame.center);
    expect(engine.channel.pointers.last.x, closeTo(.5, .01));
    expect(engine.channel.pointers.last.y, closeTo(.5, .01));

    for (final cancel in [false, true]) {
      engine.channel.pointers.clear();
      final gesture = await tester.startGesture(
        frame.center,
        pointer: cancel ? 42 : 41,
      );
      await gesture.moveTo(hidden);
      final lastValid = engine.channel.pointers.last;
      final beforeRelease = engine.channel.pointers.length;
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      expect(engine.channel.pointers, hasLength(beforeRelease + 1));
      expect(engine.channel.pointers.last.buttons, 0);
      expect(engine.channel.pointers.last.x, lastValid.x);
      expect(engine.channel.pointers.last.y, lastValid.y);
    }
  });

  testWidgets(
    'fill crops actual frame and inversely maps visible coordinates',
    (tester) async {
      final engine = UiEngine(supportsResize: false), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await selectDisplayMode(tester, RdpDisplayMode.fillWindow);
      await connectRdp(tester);
      expect(
        engine.requests.single.settings.displayMode,
        RdpDisplayMode.fillWindow,
      );
      await showFrame(tester, engine.channel);
      await tester.ensureVisible(key('rdp-surface'));
      await tester.pumpAndSettle();
      final surface = tester.getRect(key('rdp-surface'));
      final frame = tester.getRect(key('rdp-frame-image'));
      final source = engine.channel.currentDisplay!;
      expect(
        frame.width / frame.height,
        closeTo(source.width / source.height, .001),
      );
      expect(frame.width, greaterThanOrEqualTo(surface.width));
      expect(frame.height, greaterThanOrEqualTo(surface.height));
      final local = Offset(surface.width / 2, 1);
      final expected = RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.fillWindow,
        frameSize: Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: surface.size,
        devicePixelRatio: 1,
      ).normalize(local)!;
      await tester.tapAt(surface.topLeft + local);
      expect(engine.channel.pointers.last.x, closeTo(expected.dx, .01));
      expect(engine.channel.pointers.last.y, closeTo(expected.dy, .01));
      expect(expected.dy, greaterThan(0));
    },
  );

  testWidgets(
    'native is one-to-one, explicitly pannable, and never requests DISP resize',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await selectDisplayMode(tester, RdpDisplayMode.native);
      await connectRdp(tester);
      await showFrame(tester, engine.channel);
      await tester.ensureVisible(key('rdp-surface'));
      await tester.pumpAndSettle();
      expect(
        engine.requests.single.settings.displayMode,
        RdpDisplayMode.native,
      );
      final requested = engine.channel.currentDisplay!;
      expect(
        tester.getSize(key('rdp-frame-image')),
        Size(requested.width.toDouble(), requested.height.toDouble()),
      );
      expect(engine.channel.displays, isEmpty);
      expect(
        tester.getSemantics(key('rdp-native-pan')).label,
        contains('Pan native canvas'),
      );

      final surface = tester.getRect(key('rdp-surface'));
      final before = tester.getTopLeft(key('rdp-frame-image'));
      final remoteDrag = await tester.startGesture(surface.center, pointer: 43);
      await tester.pump();
      expect(engine.channel.pointers.last.buttons, greaterThan(0));
      await tester.tap(key('rdp-native-pan'));
      await tester.pump();
      expect(
        tester.getSemantics(key('rdp-native-pan')).label,
        contains('Resume remote pointer'),
      );
      expect(engine.channel.pointers.last.buttons, 0);
      final releasedCount = engine.channel.pointers.length;
      await remoteDrag.moveBy(const Offset(-40, 0));
      await remoteDrag.up();
      expect(engine.channel.pointers, hasLength(releasedCount));
      engine.channel.pointers.clear();
      await tester.timedDragFrom(
        surface.center,
        const Offset(-120, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(engine.channel.pointers, isEmpty);
      final after = tester.getTopLeft(key('rdp-frame-image'));
      expect(after.dx, lessThan(before.dx));
      expect(after.dy, before.dy);

      await tester.tap(key('rdp-native-pan'));
      await tester.pump();
      await tester.tapAt(surface.center);
      expect(engine.channel.pointers, isNotEmpty);
      expect(
        engine.channel.pointers.last.x,
        greaterThan(surface.width / (requested.width * 2)),
      );
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(engine.channel.displays, isEmpty);
      semantics.dispose();
    },
  );

  testWidgets('packaged capabilities hide unavailable IME and clipboard mode', (
    tester,
  ) async {
    final engine = UiEngine(), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    expect(key('rdp-clipboard-bidirectional'), findsNothing);
    await connectRdp(tester);
    expect(key('rdp-text-input'), findsNothing);
    expect(key('rdp-text-send'), findsNothing);
    expect(key('rdp-clipboard-clientToRemote'), findsOneWidget);
    expect(key('rdp-clipboard-bidirectional'), findsNothing);
  });

  testWidgets('persisted bidirectional mode requires explicit correction', (
    tester,
  ) async {
    final engine = UiEngine(), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await press(tester, 'rdp-back');
    final saved = await ui.read();
    await RdpSecurityStore().saveSettings(
      saved.profiles.single,
      const RdpProfileSettings(clipboardMode: RdpClipboardMode.bidirectional),
      isCurrent: () => true,
    );
    await press(tester, 'remote-rdp-open');
    await connectRdp(tester);

    expect(key('rdp-clipboard-bidirectional'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.descendant(
              of: key('rdp-clipboard-bidirectional'),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(key('rdp-clipboard-correction-required'), findsOneWidget);
    expect(
      find.textContaining('saved clipboard mode is unavailable'),
      findsOneWidget,
    );
    await press(tester, 'rdp-settings-save');
    expect(find.text('RDP settings could not be verified.'), findsOneWidget);
    expect(
      (await RdpSecurityStore().readSettings(
        saved.profiles.single,
        isCurrent: () => true,
      )).clipboardMode,
      RdpClipboardMode.bidirectional,
    );
    await press(tester, 'rdp-clipboard-disabled');
    expect(key('rdp-clipboard-correction-required'), findsNothing);
    await press(tester, 'rdp-settings-save');
    expect(
      (await RdpSecurityStore().readSettings(
        saved.profiles.single,
        isCurrent: () => true,
      )).clipboardMode,
      RdpClipboardMode.disabled,
    );
  });

  testWidgets('exact display identity change retires without replay', (
    tester,
  ) async {
    final engines = <UiEngine>[];
    RdpEngine factory() {
      final engine = UiEngine();
      engines.add(engine);
      return engine;
    }

    final ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: factory,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    expect(engines.single.requests.single.display.externalDisplay, isFalse);

    ui.windows.add(_externalWindow(4, 1));
    await tester.pumpAndSettle();
    expect(engines, hasLength(1));
    expect(key('rdp-check'), findsOneWidget);

    await connectRdp(tester);
    expect(engines, hasLength(2));
    expect(engines.last.requests.single.display.externalDisplay, isTrue);
    ui.windows.add(_externalWindow(4, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-surface')), findsOneWidget);
    expect(engines, hasLength(2));

    ui.windows.add(_externalWindow(5, 1));
    await tester.pumpAndSettle();
    expect(key('rdp-check'), findsOneWidget);
    expect(engines, hasLength(2));
    await connectRdp(tester);
    expect(engines, hasLength(3));
    expect(engines.last.requests.single.display.externalDisplay, isTrue);

    // A remove/add lifecycle can reuse a logical display ID. Its new process
    // revision must still fence the old session without reconnecting it.
    ui.windows.add(_externalWindow(5, 2));
    await tester.pumpAndSettle();
    expect(key('rdp-check'), findsOneWidget);
    expect(engines, hasLength(3));

    ui.windows.add(
      const WindowPolicySnapshot(
        supported: true,
        isResumed: true,
        hasWindowFocus: true,
        isExternalDisplay: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(key('rdp-scroll'), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(
      find.text('Window control is unavailable on this platform.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      key('rdp-check'),
      240,
      scrollable: find
          .descendant(of: key('rdp-scroll'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    final check = tester.widget<CupertinoButton>(
      find.descendant(
        of: key('rdp-check'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(check.onPressed, isNull);
    expect(engines, hasLength(3));
    expect(engines.last.requests, hasLength(1));
  });

  testWidgets('window completion unknown retires without replay', (
    tester,
  ) async {
    final engines = <UiEngine>[];
    final ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () {
        final engine = UiEngine();
        engines.add(engine);
        return engine;
      },
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    expect(engines.single.requests, hasLength(1));

    // WindowPolicyBridge emits this final unknown snapshot before its native
    // stream closes. The provider then retains the safe value, not the tuple.
    ui.windows.add(WindowPolicySnapshot.unknown);
    await tester.pumpAndSettle();
    expect(engines.single.channel.doneCompleter.isCompleted, isTrue);
    expect(engines, hasLength(1));
    expect(engines.single.requests, hasLength(1));
  });

  testWidgets(
    'display classification change during capability read cannot open transport',
    (tester) async {
      final engine = HeldCapabilityEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      held(tester, 'rdp-check')();
      await tester.pump();
      expect(engine.capabilityReads, 1);

      ui.windows.add(_externalWindow(4, 1));
      await tester.pump();
      engine.release.complete();
      await tester.pumpAndSettle();
      expect(engine.requests, isEmpty);
      expect(key('rdp-check'), findsOneWidget);
    },
  );
}
