import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/admin/data/models/ha_area.dart';
import 'package:oikos/features/admin/presentation/areas_screen.dart';
import 'package:oikos/features/admin/providers/admin_providers.dart';

void main() {
  testWidgets('renders areas from the provider without hitting the network', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          areasProvider.overrideWith(
            (ref) async => const [
              HaArea(areaId: 'kitchen', name: 'Kitchen'),
              HaArea(areaId: 'living_room', name: 'Living Room'),
            ],
          ),
        ],
        child: const CupertinoApp(home: AreasScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kitchen'), findsOneWidget);
    expect(find.text('Living Room'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no areas', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [areasProvider.overrideWith((ref) async => const [])],
        child: const CupertinoApp(home: AreasScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No areas configured'), findsOneWidget);
  });
}
