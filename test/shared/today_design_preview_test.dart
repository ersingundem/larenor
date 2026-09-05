import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/today/data/today_timezone.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/features/today/presentation/today_screen.dart';
import 'package:larenor/features/today/providers/today_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

TodaySnapshot _fixture() {
  final zone = TodayTimeZone('Europe/Istanbul');
  final now = DateTime.utc(2026, 9, 5, 9, 30);
  final day = zone.dayRange(now);
  return TodaySnapshot(
    configured: true,
    refreshedAt: now,
    timeZone: zone.name,
    dayStart: day.start,
    dayEnd: day.end,
    todoLists: [
      TodayTodoList(
        entityId: 'todo.shopping',
        title: 'Alışveriş',
        supportedFeatures: 5,
        available: true,
        items: TodayRead(
          readAt: now,
          value: const [
            TodayTodoItem(
              uid: '1',
              summary: 'Kahve çekirdeği',
              status: TodayTodoStatus.needsAction,
            ),
            TodayTodoItem(
              uid: '2',
              summary: 'Taze meyve',
              status: TodayTodoStatus.needsAction,
            ),
            TodayTodoItem(
              uid: '3',
              summary: 'Süt',
              status: TodayTodoStatus.completed,
            ),
          ],
        ),
      ),
      TodayTodoList(
        entityId: 'todo.home',
        title: 'Ev işleri',
        supportedFeatures: 5,
        available: true,
        items: TodayRead(
          readAt: now,
          value: const [
            TodayTodoItem(
              uid: '4',
              summary: 'Bitkileri sula',
              dueDate: '2026-09-05',
              status: TodayTodoStatus.needsAction,
            ),
            TodayTodoItem(
              uid: '5',
              summary: 'Hava filtresini kontrol et',
              dueDate: '2026-09-06',
              status: TodayTodoStatus.needsAction,
            ),
          ],
        ),
      ),
    ],
    calendars: [
      TodayCalendar(
        entityId: 'calendar.home',
        title: 'Ev takvimi',
        events: TodayRead(
          readAt: now,
          value: [
            TodayCalendarEvent(
              title: 'Birlikte akşam yemeği',
              start: zone.local(DateTime.utc(2026, 9, 5, 16)),
              end: zone.local(DateTime.utc(2026, 9, 5, 17)),
              allDay: false,
            ),
          ],
        ),
      ),
    ],
    notifications: TodayRead(
      readAt: now,
      value: [
        TodayNotification(
          id: 'fixture-notification',
          title: 'Ev özeti',
          message: 'Haftalık ev planın güncellendi.',
          createdAt: now,
        ),
      ],
    ),
  );
}

void main() {
  for (final dark in [false, true]) {
    for (final phone in [false, true]) {
      final name = 'today-${phone ? 'phone' : 'tablet'}${dark ? '-dark' : ''}';
      testWidgets('$name uses shared theme with daily overview fixtures', (
        tester,
      ) async {
        const out = String.fromEnvironment('DESIGN_PREVIEW_DIR');
        if (out.isNotEmpty) {
          await tester.runAsync(() async {
            final font = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(font))).load();
            }
            await (FontLoader('packages/cupertino_icons/CupertinoIcons')
                  ..addFont(
                    rootBundle.load(
                      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                    ),
                  ))
                .load();
          });
        }
        tester.view.physicalSize = phone
            ? const Size(390, 844)
            : const Size(1366, 1024);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              connectionConfigProvider.overrideWithBuild(
                (ref, notifier) async => const HaConnectionConfig(
                  baseUrl: 'https://fixture.invalid',
                  token: 'preview-fixture',
                ),
              ),
              todayProvider.overrideWith((ref) => Stream.value(_fixture())),
              todayControllerProvider.overrideWith((ref) => null),
              todayActionsProvider.overrideWith((ref) => null),
            ],
            child: CupertinoApp(
              theme: larenorTheme(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              locale: const Locale('tr'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (_, child) =>
                  RepaintBoundary(key: boundary, child: child!),
              home: const TodayScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Bugün'), findsWidgets);
        expect(tester.takeException(), isNull);
        if (out.isNotEmpty) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File('$out/$name.png')
                  .writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      });
    }
  }
}
