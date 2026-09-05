import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/data/screen_policy_controller.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';

class _Platform implements ScreenPolicyPlatform {
  final calls = <String>[];
  Future<void> Function(String)? pending;
  int active = 0, maxActive = 0;
  Future<void> _call(String value) async {
    calls.add(value);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await pending?.call(value);
    } finally {
      active--;
    }
  }

  @override
  Future<void> keepAwake(bool value) => _call('awake:$value');
  @override
  Future<void> dim() => _call('dim');
  @override
  Future<void> resetBrightness() => _call('reset');
}

Future<void> _flush() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'one platform operation at a time; late awake cannot dim after background',
    () async {
      final p = _Platform();
      final c = ScreenPolicyController(p);
      final owner = c.claim();
      await _flush();
      final block = Completer<void>();
      p.pending = (value) async {
        if (value == 'awake:true') await block.future;
      };
      c.update(owner, const ScreenPolicy(keepAwake: true, dim: true));
      await _flush();
      c.update(owner, ScreenPolicy.released);
      block.complete();
      await _flush();
      expect(p.maxActive, 1);
      expect(p.calls.last, 'awake:false');
      expect(p.calls, isNot(contains('dim')));
    },
  );
  test('late dim always resets after release', () async {
    final p = _Platform();
    final c = ScreenPolicyController(p);
    final o = c.claim();
    await _flush();
    final block = Completer<void>();
    p.pending = (v) async {
      if (v == 'dim') await block.future;
    };
    c.update(o, const ScreenPolicy(keepAwake: true, dim: true));
    await _flush();
    c.release(o);
    block.complete();
    await _flush();
    expect(p.calls.last, 'reset');
    expect(p.maxActive, 1);
  });
  test('old owner release never removes a replacement owner policy', () async {
    final p = _Platform();
    final c = ScreenPolicyController(p);
    final old = c.claim();
    await _flush();
    final block = Completer<void>();
    p.pending = (v) async {
      if (v == 'dim') await block.future;
    };
    c.update(old, const ScreenPolicy(keepAwake: true, dim: true));
    await _flush();
    final current = c.claim();
    c.update(current, const ScreenPolicy(keepAwake: true, dim: true));
    c.release(old);
    block.complete();
    await _flush();
    expect(p.calls.where((v) => v.startsWith('awake:')).last, 'awake:true');
    expect(p.calls, isNot(contains('reset')));
    c.release(current);
    await _flush();
    expect(p.calls.last, 'reset');
  });
  test('failed apply is not remembered as successful; force reasserts resumed policy', () async {
    final p = _Platform();
    final c = ScreenPolicyController(p);
    final owner = c.claim();
    await _flush();
    var fail = true;
    p.pending = (v) async {
      if (v == 'awake:true' && fail) throw StateError('unsupported');
    };
    c.update(owner, const ScreenPolicy(keepAwake: true, dim: false));
    await _flush();
    fail = false;
    c.update(owner, const ScreenPolicy(keepAwake: true, dim: false));
    await _flush();
    c.update(
      owner,
      const ScreenPolicy(keepAwake: true, dim: false),
      force: true,
    );
    await _flush();
    expect(p.calls.where((v) => v == 'awake:true'), hasLength(3));
  });
  test('failed brightness reset remains owned and is retried later', () async {
    final p = _Platform();
    final c = ScreenPolicyController(p);
    final o = c.claim();
    await _flush();
    c.update(o, const ScreenPolicy(keepAwake: false, dim: true));
    await _flush();
    var fail = true;
    p.pending = (v) async {
      if (v == 'reset' && fail) throw StateError('failed');
    };
    c.update(o, ScreenPolicy.released);
    await _flush();
    fail = false;
    c.update(o, ScreenPolicy.released);
    await _flush();
    expect(p.calls.where((v) => v == 'reset'), hasLength(2));
  });
}
