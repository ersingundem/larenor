import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

void main() {
  testWidgets('new lower-order page reorders only visible records while preserving keyed row and cursor', (tester) async {
    final h = ResourceHarness()..response = contract()['firstPage'];
    await h.mount(tester); await h.signIn(); await flush(tester);
    final room = find.byKey(ValueKey('home-resource-${'1' * 32}'));
    final originalElement = tester.element(room);
    final more = find.byKey(const ValueKey('home-resources-load-more'));
    final l10n = AppLocalizations.of(tester.element(more));
    await tester.ensureVisible(more);
    Focus.of(tester.element(find.text(l10n.homeResourcesLoadMore))).requestFocus(); await flush(tester);
    final next = contract()['secondPage'] as Map;
    next['entries'][0]['order'] = 0;
    next['nextAfter'] = next['entries'][0]['ref']['id'];
    h.response = next;
    await tester.sendKeyEvent(LogicalKeyboardKey.space); await flush(tester);
    expect(tester.getTopLeft(find.text('Okuma lambası')).dy, lessThan(tester.getTopLeft(find.text('Salon')).dy));
    expect(tester.element(room), same(originalElement));
    expect(Focus.of(tester.element(find.text(l10n.homeResourcesLoadMore))).hasPrimaryFocus, isTrue);
    expect(h.requests.last.url.queryParameters['after'], h.fixture['firstPage']['nextAfter']);
    expect(h.requests.last.url.queryParameters['expectedSnapshot'], h.fixture['firstPage']['snapshot']);
    expect(h.resourceReads, 2); expect(h.haReads, 0);
  });
}
