import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';

void main() {
  testWidgets('startup recovery blocks providers until it succeeds', (
    tester,
  ) async {
    var attempts = 0;
    var built = 0;
    await tester.pumpWidget(
      ConfigurationScope(
        initialize: () async {
          attempts++;
          if (attempts == 1) throw StateError('secret');
        },
        child: CupertinoApp(
          home: Builder(
            builder: (_) {
              built++;
              return const Text('Application');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(built, 0);
    expect(find.textContaining('secret'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(built, 1);
    expect(find.text('Application'), findsOneWidget);
  });

  testWidgets(
    'restore disposes old providers before writes and rereads storage',
    (tester) async {
      var storedValue = 'old';
      var disposed = false;
      final finish = Completer<void>();
      final config = Provider<String>((ref) {
        ref.onDispose(() => disposed = true);
        return storedValue;
      });
      await tester.pumpWidget(
        ConfigurationScope(
          child: CupertinoApp(
            home: Consumer(
              builder: (context, ref, _) => Column(
                children: [
                  Text(ref.watch(config)),
                  CupertinoButton(
                    onPressed: () => ConfigurationScope.restore(
                      context,
                      operation: () async {
                        expect(disposed, isTrue);
                        await finish.future;
                        storedValue = 'restored';
                      },
                      progressLabel: 'Restoring',
                      failureLabel: 'Failed',
                      continueLabel: 'Continue',
                    ),
                    child: const Text('Restore'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(find.text('Restoring'), findsOneWidget);
      expect(find.text('old'), findsNothing);
      finish.complete();
      await tester.pumpAndSettle();
      expect(find.text('restored'), findsOneWidget);
      expect(find.text('Restoring'), findsNothing);
    },
  );

  testWidgets(
    'failed restore hides storage error and requires explicit return',
    (tester) async {
      await tester.pumpWidget(
        ConfigurationScope(
          child: CupertinoApp(
            home: Builder(
              builder: (context) => CupertinoButton(
                onPressed: () => ConfigurationScope.restore(
                  context,
                  operation: () async => throw StateError('SECRET'),
                  progressLabel: 'Restoring',
                  failureLabel: 'Restore failed; check saved connections',
                  continueLabel: 'Continue',
                ),
                child: const Text('Restore'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(
        find.text('Restore failed; check saved connections'),
        findsOneWidget,
      );
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('Restore'), findsNothing);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
