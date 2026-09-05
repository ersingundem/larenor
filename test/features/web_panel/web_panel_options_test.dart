import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';

void main() {
  test('explicit grants preserve exact origin boundaries and roundtrip preferences', () {
    final options = WebPanelOptions(
      additionalOrigins: ['https://login.invalid:8443'],
      zoomEnabled: false,
      textZoom: 150,
    );
    final tile = TileConfig(
      id: 'web',
      type: TileType.webview,
      x: 0,
      y: 0,
      width: 2,
      height: 2,
      url: 'https://panel.invalid/start',
      webPanel: options,
    );
    final json = tile.toJson();
    validateDashboardLayoutJson({
      'tiles': [json],
    });
    expect(TileConfig.fromJson(json).webPanel, options);
    final policy = options.policyFor(tile.url!)!;
    expect(
      policy.allows('https://login.invalid:8443/oauth?code=synthetic'),
      true,
    );
    for (final url in [
      'https://login.invalid/oauth',
      'https://child.login.invalid:8443',
      'http://login.invalid:8443',
    ]) {
      expect(policy.allows(url), false);
    }
  });
  test('legacy web cards retain safe default preferences', () {
    final tile = TileConfig.fromJson({
      'id': 'web',
      'type': 'webview',
      'x': 0,
      'y': 0,
      'width': 2,
      'height': 2,
      'url': 'https://panel.invalid',
    });
    expect(tile.webPanel, null);
    expect(WebPanelOptions.fromJson({}).zoomEnabled, true);
    expect(WebPanelOptions.fromJson({}).textZoom, 100);
  });
  test('grant rejects paths OAuth queries wildcard credentials and ambiguous encodings', () {
    for (final value in [
      'https://site.invalid/path',
      'https://site.invalid?code=synthetic',
      'https://site.invalid#token',
      'https://user:pass@site.invalid',
      'https://%73ite.invalid',
      '*',
      'file:///private/file',
      'https://site.invalid\\evil',
      'https://site.invalid/%0a',
    ]) {
      expect(WebOrigin.parseExact(value), null, reason: value);
      expect(
        () => WebPanelOptions(additionalOrigins: [value]),
        throwsFormatException,
      );
    }
  });
  test(
    'schema rejects unbounded duplicate noncanonical and wrong-typed options',
    () {
      for (final value in [
        {
          'additionalOrigins': List.generate(
            16,
            (i) => 'https://site$i.invalid',
          ),
        },
        {
          'additionalOrigins': ['https://site.invalid', 'https://site.invalid'],
        },
        {
          'additionalOrigins': ['https://SITE.invalid/'],
        },
        {'additionalOrigins': null},
        {'textZoom': null},
        {'textZoom': 74},
        {'textZoom': 201},
        {'textZoom': 100.5},
        {'zoomEnabled': 1},
        {'unknown': 'field'},
      ]) {
        expect(
          () => WebPanelOptions.validateJson(value),
          throwsFormatException,
        );
      }
      expect(
        hasValidWebPanelTileFields({'type': 'camera', 'webPanel': {}}),
        false,
      );
      expect(
        hasValidWebPanelTileFields({
          'type': 'webview',
          'webPanel': {},
          'url': 'javascript:evil',
        }),
        false,
      );
    },
  );
}
