import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/flow_schema_field.dart';

void main() {
  group('legacy `type`-based fields', () {
    test('string -> text', () {
      final field = FlowSchemaField.fromJson({
        'name': 'host',
        'type': 'string',
      });
      expect(field.kind, FlowFieldKind.text);
    });

    test('integer -> integer', () {
      final field = FlowSchemaField.fromJson({
        'name': 'port',
        'type': 'integer',
      });
      expect(field.kind, FlowFieldKind.integer);
    });

    test('float -> number', () {
      final field = FlowSchemaField.fromJson({
        'name': 'threshold',
        'type': 'float',
      });
      expect(field.kind, FlowFieldKind.number);
    });

    test('boolean -> boolean', () {
      final field = FlowSchemaField.fromJson({
        'name': 'ssl',
        'type': 'boolean',
      });
      expect(field.kind, FlowFieldKind.boolean);
    });

    test('unknown legacy type -> rawFallback', () {
      final field = FlowSchemaField.fromJson({
        'name': 'weird',
        'type': 'vol.Schema',
      });
      expect(field.kind, FlowFieldKind.rawFallback);
    });
  });

  group('modern `selector`-based fields', () {
    test('selector.text -> text', () {
      final field = FlowSchemaField.fromJson({
        'name': 'host',
        'selector': {'text': {}},
      });
      expect(field.kind, FlowFieldKind.text);
    });

    test('selector.number -> number', () {
      final field = FlowSchemaField.fromJson({
        'name': 'port',
        'selector': {'number': {}},
      });
      expect(field.kind, FlowFieldKind.number);
    });

    test('selector.boolean -> boolean', () {
      final field = FlowSchemaField.fromJson({
        'name': 'ssl',
        'selector': {'boolean': {}},
      });
      expect(field.kind, FlowFieldKind.boolean);
    });

    test('selector.select -> select, with options parsed', () {
      final field = FlowSchemaField.fromJson({
        'name': 'mode',
        'selector': {
          'select': {
            'options': [
              {'value': 'a', 'label': 'Option A'},
              {'value': 'b', 'label': 'Option B'},
            ],
          },
        },
      });
      expect(field.kind, FlowFieldKind.select);
      expect(field.options, hasLength(2));
      expect(field.options.first.value, 'a');
      expect(field.options.first.label, 'Option A');
    });

    test(
      'selector.select with plain string options falls back to value as label',
      () {
        final field = FlowSchemaField.fromJson({
          'name': 'mode',
          'selector': {
            'select': {
              'options': ['a', 'b'],
            },
          },
        });
        expect(field.options.map((o) => o.label), ['a', 'b']);
      },
    );

    test('device selector uses the native device picker', () {
      final field = FlowSchemaField.fromJson({
        'name': 'target_device',
        'selector': {'device': {}},
      });
      expect(field.kind, FlowFieldKind.device);
    });
  });

  group('typed submission', () {
    test(
      'untouched optional fields omitted, required boolean and defaults kept',
      () {
        final fields = [
          FlowSchemaField.fromJson({'name': 'optional', 'type': 'string'}),
          FlowSchemaField.fromJson({
            'name': 'port',
            'type': 'integer',
            'default': 8123,
          }),
          FlowSchemaField.fromJson({
            'name': 'ssl',
            'type': 'boolean',
            'required': true,
          }),
        ];
        expect(normalizeFlowValues(fields, {}), {'port': 8123, 'ssl': false});
      },
    );

    test(
      'numbers are parsed and invalid, nonfinite, out-of-range inputs rejected',
      () {
        final field = FlowSchemaField.fromJson({
          'name': 'level',
          'required': true,
          'selector': {
            'number': {'min': 0, 'max': 100},
          },
        });
        expect(normalizeFlowValues([field], {'level': '42.5'}), {
          'level': 42.5,
        });
        for (final bad in ['', 'abc', 'NaN', 'Infinity', '-1', '101']) {
          expect(
            () => normalizeFlowValues([field], {'level': bad}),
            throwsFormatException,
          );
        }
      },
    );

    test(
      'select options preserve typed values and multi-select validates members',
      () {
        final field = FlowSchemaField.fromJson({
          'name': 'codes',
          'type': 'multi_select',
          'options': [
            [1, 'One'],
            [2, 'Two'],
          ],
        });
        expect(
          normalizeFlowValues(
            [field],
            {
              'codes': [1, 2],
            },
          ),
          {
            'codes': [1, 2],
          },
        );
        expect(field.validateValue(['1']), 'invalid');
        expect(field.validateValue(1), 'invalid');
      },
    );

    test('raw typed strings are never decoded as JSON a second time', () {
      final field = FlowSchemaField.fromJson({
        'name': 'advanced',
        'default': 'plain token',
      });
      expect(normalizeFlowValues([field], {}), {'advanced': 'plain token'});
      expect(normalizeFlowValues([field], {'advanced': '{"literal":true}'}), {
        'advanced': '{"literal":true}',
      });
      expect(
        normalizeFlowValues(
          [field],
          {'advanced': const RawFlowJsonInput('{"nested":[1,true]}')},
        ),
        {
          'advanced': {
            'nested': [1, true],
          },
        },
      );
      expect(field.validateValue(const RawFlowJsonInput('{bad')), 'invalid');
      expect(
        field.parseValue(const RawFlowJsonInput('"plain token"')),
        'plain token',
      );
    });

    test('modern entity filters use OR alternatives and feature bits', () {
      final field = FlowSchemaField.fromJson({
        'name': 'entity',
        'selector': {
          'entity': {
            'exclude_entities': ['light.excluded'],
            'filter': [
              {
                'domain': 'light',
                'supported_features': [4, 8],
              },
              {
                'domain': 'sensor',
                'device_class': 'temperature',
                'unit_of_measurement': ['°C', '°F'],
              },
            ],
          },
        },
      });
      expect(
        field.matchesEntity(
          'light.ceiling',
          attributes: {'supported_features': 8},
        ),
        isTrue,
      );
      expect(
        field.matchesEntity(
          'light.ceiling',
          attributes: {'supported_features': 2},
        ),
        isFalse,
      );
      expect(
        field.matchesEntity(
          'light.excluded',
          attributes: {'supported_features': 4},
        ),
        isFalse,
      );
      expect(
        field.matchesEntity(
          'sensor.room',
          attributes: {
            'device_class': 'temperature',
            'unit_of_measurement': '°C',
          },
        ),
        isTrue,
      );
      expect(field.matchesEntity('switch.room'), isFalse);
    });
  });

  group('shared field metadata', () {
    test('required and default are captured regardless of shape', () {
      final field = FlowSchemaField.fromJson({
        'name': 'port',
        'required': true,
        'default': 8123,
        'type': 'integer',
      });
      expect(field.required, isTrue);
      expect(field.defaultValue, 8123);
    });

    test('missing required defaults to false', () {
      final field = FlowSchemaField.fromJson({
        'name': 'host',
        'type': 'string',
      });
      expect(field.required, isFalse);
    });

    test('field with neither type nor selector -> rawFallback', () {
      final field = FlowSchemaField.fromJson({'name': 'mystery'});
      expect(field.kind, FlowFieldKind.rawFallback);
    });
  });
}
