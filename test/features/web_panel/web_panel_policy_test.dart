import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:larenor/features/web_panel/data/web_panel_navigation_budget.dart';

void main() {
  test('exact origin normalizes default ports without widening authority', () {
    final policy = WebPanelPolicy.fromUrl(
      'https://home.example/start?private=query#fragment',
    )!;
    expect(policy.allows('https://HOME.example:443/other'), true);
    for (final url in [
      'http://home.example/',
      'https://home.example:444/',
      'https://sub.home.example/',
      'https://home.example.evil/',
      'https://other.example/',
      'https://home.example@evil/',
      'https://home.example%2eevil/',
      'https://home.example/%0asecret',
      r'https://home.example\@evil/',
      'file:///home.example',
      'about:blank',
      'javascript:alert(1)',
    ]) {
      expect(policy.allows(url), false, reason: url);
    }
    expect(
      WebOrigin.parse('https://home.example/private?token=fixture#value')!
          .displayName,
      'https://home.example',
    );
  });
  test('IPv6 and explicitly configured additional origin keep exact ports', () {
    final policy = WebPanelPolicy.fromUrl(
      'http://[2001:db8::1]:8123/',
      additionalOrigins: {WebOrigin.parse('https://login.example')!},
    )!;
    expect(policy.allows('http://[2001:db8::1]:8123/ui'), true);
    expect(policy.allows('http://[2001:db8::1]/ui'), false);
    expect(policy.allows('https://login.example/auth'), true);
    expect(policy.allows('https://sub.login.example/auth'), false);
    expect(
      WebOrigin.parse('http://[2001:db8::1]:8123/secret')!.displayName,
      'http://[2001:db8::1]:8123',
    );
  });
  test('equivalent rebuilds preserve policy; endpoint and grants do not', () {
    final a = WebPanelPolicy.fromUrl('https://home.example');
    final b = WebPanelPolicy.fromUrl('https://home.example');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(WebPanelPolicy.fromUrl('https://home.example/new')));
    expect(
      a,
      isNot(
        WebPanelPolicy.fromUrl(
          'https://home.example',
          additionalOrigins: {WebOrigin.parse('https://login.example')!},
        ),
      ),
    );
  });
  test(
    'navigation budget bounds loop independently from page finish events',
    () {
      var now = DateTime.utc(2026, 9, 5);
      final budget = WebPanelNavigationBudget(now: () => now);
      for (var i = 0; i < 20; i++) {
        expect(budget.take(), true);
      }
      expect(budget.take(), false);
      now = now.add(const Duration(seconds: 29));
      expect(budget.take(), false);
      now = now.add(const Duration(seconds: 1));
      expect(budget.take(), true);
    },
  );
}
