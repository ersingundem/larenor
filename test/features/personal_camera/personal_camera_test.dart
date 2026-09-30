import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/personal_camera/data/personal_camera_controller.dart';
import 'package:larenor/features/personal_camera/data/personal_camera_platform.dart';
import 'package:larenor/features/personal_camera/presentation/personal_camera_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final _capabilities = PersonalCameraCapabilities(
  platform: 'android',
  osApiLevel: 35,
  frontCamera: true,
  preview: true,
  detectorArtifact: 'com.google.mlkit:face-detection',
  detectorVersion: '16.1.7',
  detectorDelivery: 'bundled',
  requiresGooglePlayServices: false,
  faceDetection: true,
  identityRecognition: false,
  personalizationMatching: true,
  termsUrl: Uri(
    scheme: 'https',
    host: 'developers.google.com',
    path: '/ml-kit/terms',
  ),
  performanceEvaluation: 'pending',
);

final _profile = PersonalFaceProfile(
  id: '01234567-89ab-4cde-8fab-0123456789ab',
  createdAt: DateTime.utc(2026, 9, 30),
  sampleCount: 8,
  detectorVersion: '16.1.7',
);

final class _Platform implements PersonalCameraPlatform {
  _Platform() {
    eventsController = StreamController<PersonalCameraEvent>.broadcast(
      onCancel: () => eventCancellations++,
    );
  }

  late final StreamController<PersonalCameraEvent> eventsController;
  final opens = <Completer<PersonalCameraSession>>[];
  PersonalFaceProfile? storedProfile = _profile;
  int closeCalls = 0;
  int deleteCalls = 0;
  int eventCancellations = 0;
  bool failClose = false;

  @override
  Stream<PersonalCameraEvent> get events => eventsController.stream;

  @override
  Future<PersonalCameraCapabilities> capabilities() async => _capabilities;

  @override
  Future<PersonalFaceProfile?> profile() async => storedProfile;

  @override
  Future<PersonalCameraSession> open() {
    final operation = Completer<PersonalCameraSession>();
    opens.add(operation);
    return operation.future;
  }

  @override
  Future<void> close(String sessionId) async {
    closeCalls++;
    if (failClose) {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

  @override
  Future<PersonalFaceProfile> enroll(String sessionId) async => _profile;

  @override
  Future<PersonalFaceMatch> match(String sessionId) async =>
      const PersonalFaceMatch(
        profileId: '01234567-89ab-4cde-8fab-0123456789ab',
        state: PersonalFaceMatchState.matched,
        sampleCount: 5,
      );

  @override
  Future<void> deleteProfile(String profileId) async {
    deleteCalls++;
    storedProfile = null;
  }

  Future<void> dispose() => eventsController.close();
}

Future<void> _mount(
  WidgetTester tester,
  _Platform platform,
  AppInteractionController interaction,
) async {
  await tester.pumpWidget(
    AppInteractionScope(
      controller: interaction,
      child: CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PersonalCameraScreen(platform: platform),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'late native open is closed and never published after authority loss',
    () async {
      final platform = _Platform();
      addTearDown(platform.dispose);
      var current = true;
      final controller = PersonalCameraController(
        platform: platform,
        isCurrent: () => current,
      );
      addTearDown(controller.dispose);

      final opening = controller.open();
      expect(platform.opens, hasLength(1));
      current = false;
      platform.opens.single.complete(
        const PersonalCameraSession(
          id: 'session-a',
          textureId: 7,
          width: 1280,
          height: 720,
        ),
      );
      await opening;

      expect(controller.session, isNull);
      expect(platform.closeCalls, 1);
    },
  );

  test(
    'unconfirmed close permanently fences the controller from reopening',
    () async {
      final platform = _Platform()..failClose = true;
      addTearDown(platform.dispose);
      final controller = PersonalCameraController(
        platform: platform,
        isCurrent: () => true,
        closeTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      final opening = controller.open();
      platform.opens.single.complete(
        const PersonalCameraSession(
          id: 'session-b',
          textureId: 9,
          width: 1280,
          height: 720,
        ),
      );
      await opening;
      await controller.close();
      await controller.open();

      expect(platform.opens, hasLength(1));
      expect(controller.failure, PersonalCameraFailure.unavailable);
      expect(platform.eventCancellations, 1);
    },
  );

  testWidgets('captured profile deletion expires before local mutation', (
    tester,
  ) async {
    final platform = _Platform();
    addTearDown(platform.dispose);
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, platform, interaction);

    final delete = find.byKey(const ValueKey('personal-camera-profile-delete'));
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    interaction.setActive(false);
    await tester.pump();
    await tester.tap(find.text('Delete face profile').last);
    await tester.pumpAndSettle();

    expect(platform.deleteCalls, 0);
    expect(find.textContaining('Encrypted profile ready'), findsOneWidget);
  });

  testWidgets('current explicit confirmation deletes exactly one profile', (
    tester,
  ) async {
    final platform = _Platform();
    addTearDown(platform.dispose);
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, platform, interaction);

    final delete = find.byKey(const ValueKey('personal-camera-profile-delete'));
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete face profile').last);
    await tester.pumpAndSettle();

    expect(platform.deleteCalls, 1);
    expect(find.text('No local face profile is registered.'), findsOneWidget);
  });

  testWidgets(
    'captured delete confirmation cannot delete or pop a foreign route',
    (tester) async {
      final platform = _Platform();
      addTearDown(platform.dispose);
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await _mount(tester, platform, interaction);

      final delete = find.byKey(
        const ValueKey('personal-camera-profile-delete'),
      );
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      final destructive = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoDialogAction && widget.isDestructiveAction,
      );
      final captured = tester
          .widget<CupertinoDialogAction>(destructive)
          .onPressed!;
      final navigator = Navigator.of(
        tester.element(find.byType(PersonalCameraScreen)),
      );
      final foreignDone = navigator.push<void>(
        CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            key: ValueKey('foreign-route'),
            child: Center(child: Text('Foreign route')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      captured();
      await tester.pumpAndSettle();

      expect(platform.deleteCalls, 0);
      expect(find.byKey(const ValueKey('foreign-route')), findsOneWidget);

      navigator.pop();
      await foreignDone;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(platform.deleteCalls, 0);
    },
  );

  test('method channel uses exact local-only camera contract', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.ersingundem.larenor/personal_camera');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => {
          'schemaVersion': 1,
          'platform': 'android',
          'osApiLevel': 35,
          'frontCamera': true,
          'preview': true,
          'detectorArtifact': 'com.google.mlkit:face-detection',
          'detectorVersion': '16.1.7',
          'detectorDelivery': 'bundled',
          'requiresGooglePlayServices': false,
          'faceDetection': true,
          'identityRecognition': false,
          'personalizationMatching': true,
          'termsUrl': 'https://developers.google.com/ml-kit/terms',
          'performanceEvaluation': 'pending',
        },
        'open' => {
          'schemaVersion': 1,
          'sessionId': 'session-c',
          'textureId': 11,
          'width': 1280,
          'height': 720,
        },
        'close' => {
          'schemaVersion': 1,
          'sessionId': 'session-c',
          'closed': true,
        },
        _ => throw PlatformException(code: 'invalid'),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const platform = MethodChannelPersonalCameraPlatform();

    final capabilities = await platform.capabilities();
    final session = await platform.open();
    await platform.close(session.id);

    expect(capabilities.requiresGooglePlayServices, isFalse);
    expect(capabilities.identityRecognition, isFalse);
    expect(calls.map((call) => call.method), ['capabilities', 'open', 'close']);
    expect(calls[0].arguments, {'schemaVersion': 1});
    expect(calls[2].arguments, {'schemaVersion': 1, 'sessionId': 'session-c'});
  });
}
