import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_editor_screen.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/section_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository extends DashboardRepository {
  _Repository(String room)
    : saved = DashboardLayout(
        rooms: [DashboardRoom(id: 'living', name: room)],
        tiles: const [
          TileConfig(
            id: 'manual',
            type: TileType.entity,
            entityId: 'sensor.synthetic',
            x: 0,
            y: 0,
            width: 2,
            height: 1,
          ),
        ],
      );
  DashboardLayout saved;
  int writes = 0;
  @override
  Future<DashboardLayout> load() async => saved;
  @override
  Future<void> save(
    DashboardLayout layout, {
    bool Function()? isCurrent,
  }) async {
    saved = layout;
    writes++;
  }
}

int labelCount(SemanticsNode node, String label) {
  var count = node.label == label ? 1 : 0;
  node.visitChildren((child) {
    count += labelCount(child, label);
    return true;
  });
  return count;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'dashboard names each section action and preserves activation ($language ${width}px 2x)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          final semantics = tester.ensureSemantics();
          addTearDown(semantics.dispose);
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final roomName = language == 'en' ? 'Living room' : 'Oturma odası';
          final roomLabel = language == 'en'
              ? '$roomName room menu'
              : '$roomName oda menüsü';
          final services = language == 'en' ? 'Services' : 'Servisler';
          final widgets = language == 'en' ? 'Widgets' : 'Bileşenler';
          final repository = _Repository(roomName);
          final initial = repository.saved;
          final navigator = GlobalKey<NavigatorState>();
          final container = ProviderContainer(
            overrides: [
              dashboardRepositoryProvider.overrideWithValue(repository),
              connectionConfigProvider.overrideWithBuild(
                (ref, notifier) async => const HaConnectionConfig(
                  baseUrl: 'https://ha.invalid',
                  token: 'synthetic-only',
                ),
              ),
              entitiesProvider.overrideWithBuild((ref, notifier) async => {}),
              haRestClientProvider.overrideWithValue(null),
              haWebSocketClientProvider.overrideWithValue(null),
              haConnectionStatusProvider.overrideWith(
                (ref) => Stream.value(HaConnectionStatus.connected),
              ),
              enabledServicesProvider.overrideWithBuild(
                (ref, notifier) async => {AppService.sonarr},
              ),
              sonarrConnectionProvider.overrideWithBuild(
                (ref, notifier) async => null,
              ),
              sonarrCalendarProvider.overrideWith((ref) async => []),
            ],
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            container.dispose();
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: CupertinoApp(
                navigatorKey: navigator,
                theme: larenorTheme(),
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: const HomeDashboardScreen(embedded: true),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final mainScroll = find
              .descendant(
                of: find.byKey(const PageStorageKey('home-overview')),
                matching: find.byType(Scrollable),
              )
              .first;

          Future<Finder> verifyHeader(String title, String action) async {
            final section = find.byWidgetPredicate(
              (widget) => widget is SectionHeader && widget.title == title,
            );
            await tester.scrollUntilVisible(
              section,
              240,
              scrollable: mainScroll,
            );
            await Scrollable.ensureVisible(
              tester.element(section),
              alignment: 0.35,
            );
            await tester.pumpAndSettle();
            final button = find.descendant(
              of: section,
              matching: find.byType(CupertinoButton),
            );
            final node = tester.getSemantics(
              find.descendant(of: button, matching: find.byType(Icon)),
            );
            expect(
              node,
              isSemantics(
                label: action,
                isButton: true,
                isHeader: false,
                hasTapAction: true,
                isFocusable: true,
              ),
            );
            expect(labelCount(node.owner!.rootSemanticsNode!, action), 1);
            final heading = tester.getSemantics(
              find.descendant(of: section, matching: find.text(title)),
            );
            expect(
              heading,
              isSemantics(
                label: title,
                isHeader: true,
                isButton: false,
                hasTapAction: false,
              ),
            );
            expect(heading.id, isNot(node.id));
            final rect = tester.getRect(button);
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(tester.takeException(), isNull);
            return button;
          }

          final room = await verifyHeader(roomName, roomLabel);
          for (final keyboard in [true, false]) {
            if (keyboard) {
              Focus.of(
                tester.element(
                  find.descendant(of: room, matching: find.byType(Icon)),
                ),
              ).requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.space);
            } else {
              final node = tester.getSemantics(
                find.descendant(of: room, matching: find.byType(Icon)),
              );
              node.owner!.performAction(node.id, ui.SemanticsAction.tap);
            }
            await tester.pumpAndSettle();
            expect(find.byType(CupertinoActionSheet), findsOneWidget);
            expect(
              find.byKey(const ValueKey('room-menu-edit')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('room-menu-remove')),
              findsOneWidget,
            );
            expect(find.byType(CupertinoAlertDialog), findsNothing);
            expect(repository.saved, initial);
            expect(repository.writes, 0);
            final cancel = find.widgetWithText(
              CupertinoActionSheetAction,
              language == 'en' ? 'Cancel' : 'İptal',
            );
            await tester.tap(cancel);
            await tester.pumpAndSettle();
            expect(find.byType(CupertinoActionSheet), findsNothing);
          }
          for (final entry in [
            (services, DashboardEditorMode.services),
            (widgets, DashboardEditorMode.widgets),
          ]) {
            final label = language == 'en'
                ? 'Edit ${entry.$1} section'
                : '${entry.$1} bölümünü düzenle';
            final button = await verifyHeader(entry.$1, label);
            final node = tester.getSemantics(
              find.descendant(of: button, matching: find.byType(Icon)),
            );
            node.owner!.performAction(node.id, ui.SemanticsAction.tap);
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<DashboardCardEditorScreen>(
                    find.byType(DashboardCardEditorScreen),
                  )
                  .mode,
              entry.$2,
            );
            expect(repository.saved, initial);
            expect(repository.writes, 0);
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            expect(find.byType(DashboardCardEditorScreen), findsNothing);
          }
          expect(repository.saved, initial);
          expect(repository.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
