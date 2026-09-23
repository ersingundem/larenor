import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_external_actions.dart';

final class _Port implements WebPanelExternalActionPort {
  _Port({this.result = true, this.gate});

  final bool result;
  final Completer<void>? gate;
  int launches = 0;
  WebPanelExternalAction? last;

  @override
  Future<bool> launch(WebPanelExternalAction action) async {
    launches++;
    last = action;
    await gate?.future;
    return result;
  }
}

void main() {
  test('external action parser accepts only bounded secret-free targets', () {
    final email = WebPanelExternalAction.parse('mailto:person@example.com');
    final phone = WebPanelExternalAction.parse('tel:+902121234567');
    final map = WebPanelExternalAction.parse('geo:41.0082,28.9784');

    expect(email?.kind, WebPanelExternalActionKind.email);
    expect(email?.display, 'person@example.com');
    expect(phone?.kind, WebPanelExternalActionKind.phone);
    expect(phone?.display, '+902121234567');
    expect(map?.kind, WebPanelExternalActionKind.map);
    expect(map?.display, '41.0082,28.9784');

    for (final rejected in [
      'intent://panel/#Intent;scheme=https;end',
      'mailto:person@example.com?body=secret',
      'mailto:first@example.com,second@example.com',
      'tel:+90212;postd=1234',
      'geo:91,28',
      'geo:41,181',
      'sms:+902121234567',
      'javascript:alert(1)',
      'mailto:${'a' * 2050}@example.com',
      'mailto:person%0a@example.com',
    ]) {
      expect(WebPanelExternalAction.parse(rejected), isNull, reason: rejected);
    }
  });

  test('fresh one-shot grant previews then launches exactly once', () async {
    var now = DateTime.utc(2026, 9, 23);
    var current = true;
    final port = _Port();
    final controller = WebPanelExternalActionController(
      enabled: true,
      port: port,
      isCurrent: () => current,
      now: () => now,
    );

    expect(controller.capture('tel:+902121234567', mainFrame: true), isTrue);
    expect(controller.status, WebPanelExternalActionStatus.denied);
    controller.arm();
    expect(controller.capture('tel:+902121234567', mainFrame: false), isFalse);
    expect(controller.capture('tel:+902121234567', mainFrame: true), isTrue);
    expect(
      controller.status,
      WebPanelExternalActionStatus.awaitingConfirmation,
    );
    expect(controller.pending?.display, '+902121234567');

    await controller.confirm();
    expect(controller.status, WebPanelExternalActionStatus.unconfirmed);
    expect(port.launches, 1);
    expect(port.last?.uri.toString(), 'tel:+902121234567');
    await controller.confirm();
    expect(port.launches, 1);

    now = now.add(const Duration(seconds: 31));
    controller.arm();
    now = now.add(const Duration(seconds: 31));
    expect(
      controller.capture('mailto:person@example.com', mainFrame: true),
      isTrue,
    );
    expect(controller.status, WebPanelExternalActionStatus.denied);
    current = false;
    controller.dispose();
  });

  test('lifecycle retirement drops a late launch result without replay', () async {
    var current = true;
    final gate = Completer<void>();
    final port = _Port(gate: gate);
    final controller = WebPanelExternalActionController(
      enabled: true,
      port: port,
      isCurrent: () => current,
    );
    controller.arm();
    expect(
      controller.capture('geo:41.0082,28.9784', mainFrame: true),
      isTrue,
    );
    final pending = controller.confirm();
    expect(port.launches, 1);
    current = false;
    controller.retire();
    gate.complete();
    await pending;

    expect(controller.status, WebPanelExternalActionStatus.idle);
    expect(port.launches, 1);
    await controller.confirm();
    expect(port.launches, 1);
    controller.dispose();
  });
}
