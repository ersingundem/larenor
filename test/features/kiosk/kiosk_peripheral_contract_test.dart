import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/domain/kiosk_peripheral_contract.dart';

const authority = KioskPeripheralAuthority(
  deviceRevision: 7,
  policyRevision: 11,
  sessionEpoch: 13,
  routeEpoch: 17,
  lifecycleEpoch: 19,
);

Map<String, Object?> provider(
  String id,
  String kind, {
  int revision = 3,
  bool supported = true,
  bool enabledByUser = true,
  String permission = 'granted',
  bool connected = true,
  bool requiresGms = false,
  int maxPayloadBytes = 512,
}) => {
  'providerId': id,
  'kind': kind,
  'revision': revision,
  'supported': supported,
  'enabledByUser': enabledByUser,
  'permission': permission,
  'connected': connected,
  'requiresGms': requiresGms,
  'maxPayloadBytes': maxPayloadBytes,
};

Map<String, Object?> inventoryRaw() => {
  'schemaVersion': 1,
  'inventoryRevision': 5,
  'providers': [
    provider('qr.local_camera', 'qr'),
    provider('nfc.android', 'nfc', permission: 'denied'),
    provider('ble.local', 'ble'),
    provider('ble.play_services', 'ble', requiresGms: true),
    provider('usb.hid', 'usb', connected: false),
    provider(
      'tts.android',
      'tts',
      permission: 'notRequired',
      maxPayloadBytes: 0,
    ),
    provider(
      'print.android',
      'print',
      permission: 'notRequired',
      maxPayloadBytes: 0,
    ),
  ],
};

Map<String, Object?> inputRaw({
  String eventId = '0123456789abcdef0123456789abcdef',
  String providerId = 'qr.local_camera',
  String kind = 'qr',
  int capabilityRevision = 3,
  int sequence = 1,
  int capturedAtElapsedMs = 49000,
  String payload = 'javascript:alert(1)',
}) => {
  'schemaVersion': 1,
  'eventId': eventId,
  'providerId': providerId,
  'kind': kind,
  'capabilityRevision': capabilityRevision,
  'deviceRevision': 7,
  'policyRevision': 11,
  'sessionEpoch': 13,
  'routeEpoch': 17,
  'lifecycleEpoch': 19,
  'sequence': sequence,
  'capturedAtElapsedMs': capturedAtElapsedMs,
  'payload': payload,
};

void main() {
  test('inventory separates opt-in, permission, connection and GMS state', () {
    final inventory = KioskPeripheralInventory.fromChannel(
      inventoryRaw(),
      gmsAvailable: false,
    );

    expect(inventory.providers.map((item) => item.kind).toSet(), {
      KioskPeripheralKind.qr,
      KioskPeripheralKind.nfc,
      KioskPeripheralKind.ble,
      KioskPeripheralKind.usb,
      KioskPeripheralKind.tts,
      KioskPeripheralKind.print,
    });
    expect(
      inventory.provider('qr.local_camera').availability,
      KioskPeripheralAvailability.ready,
    );
    expect(
      inventory.provider('nfc.android').availability,
      KioskPeripheralAvailability.permissionDenied,
    );
    expect(
      inventory.provider('ble.play_services').availability,
      KioskPeripheralAvailability.gmsUnavailable,
    );
    expect(
      inventory.provider('usb.hid').availability,
      KioskPeripheralAvailability.disconnected,
    );

    final disabled = inventoryRaw();
    (disabled['providers']! as List<Object?>)[0] = provider(
      'qr.local_camera',
      'qr',
      enabledByUser: false,
    );
    expect(
      KioskPeripheralInventory.fromChannel(
        disabled,
        gmsAvailable: false,
      ).provider('qr.local_camera').availability,
      KioskPeripheralAvailability.disabled,
    );
  });

  test('input stays untrusted review-only data and rejects unsafe scope', () {
    final inventory = KioskPeripheralInventory.fromChannel(
      inventoryRaw(),
      gmsAvailable: false,
    );
    final gate = KioskPeripheralInputGate();
    final input = gate.accept(
      inputRaw(),
      inventory: inventory,
      expectedAuthority: authority,
      isCurrent: () => true,
      nowElapsedMs: 50000,
    );

    expect(input.payload, 'javascript:alert(1)');
    expect(input.disposition, KioskPeripheralDisposition.reviewOnly);
    expect(input.canExecuteCommand, isFalse);
    expect(input.canInjectJavaScript, isFalse);
    expect(jsonEncode(input.toAuditJson()), isNot(contains(input.payload)));

    for (final invalid in [
      inputRaw(providerId: 'nfc.android', kind: 'nfc'),
      inputRaw(providerId: 'usb.hid', kind: 'usb'),
      inputRaw(providerId: 'tts.android', kind: 'tts'),
      inputRaw(capabilityRevision: 4),
      {...inputRaw(), 'routeEpoch': 18},
      {...inputRaw(), 'extra': 'execute'},
      inputRaw(payload: 'x' * 513),
    ]) {
      expect(
        () => KioskPeripheralInputGate().accept(
          invalid,
          inventory: inventory,
          expectedAuthority: authority,
          isCurrent: () => true,
          nowElapsedMs: 50000,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('duplicate, replay, stale and revoked input fail closed', () {
    final inventory = KioskPeripheralInventory.fromChannel(
      inventoryRaw(),
      gmsAvailable: false,
    );
    final gate = KioskPeripheralInputGate();
    gate.accept(
      inputRaw(sequence: 9),
      inventory: inventory,
      expectedAuthority: authority,
      isCurrent: () => true,
      nowElapsedMs: 50000,
    );

    for (final replay in [
      inputRaw(sequence: 9),
      inputRaw(eventId: '1123456789abcdef0123456789abcdef', sequence: 8),
      inputRaw(
        eventId: '2123456789abcdef0123456789abcdef',
        sequence: 10,
        capturedAtElapsedMs: 1000,
      ),
    ]) {
      expect(
        () => gate.accept(
          replay,
          inventory: inventory,
          expectedAuthority: authority,
          isCurrent: () => true,
          nowElapsedMs: 50000,
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      () => gate.accept(
        inputRaw(eventId: '3123456789abcdef0123456789abcdef', sequence: 10),
        inventory: inventory,
        expectedAuthority: authority,
        isCurrent: () => false,
        nowElapsedMs: 50000,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
