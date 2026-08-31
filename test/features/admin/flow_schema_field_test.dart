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

    test('unrecognized selector kind (e.g. device picker) -> rawFallback', () {
      final field = FlowSchemaField.fromJson({
        'name': 'target_device',
        'selector': {'device': {}},
      });
      expect(field.kind, FlowFieldKind.rawFallback);
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
