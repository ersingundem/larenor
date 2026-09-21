import 'package:flutter/foundation.dart';

enum LegacyRemoteProtocol { ir, rf }

enum LegacyRemoteProvider { homeAssistant, isolatedBridge }

enum LegacyRemoteDispatchStatus { dispatched, uncertain }

enum LegacyRemoteCommandKey {
  powerToggle,
  powerOn,
  powerOff,
  volumeUp,
  volumeDown,
  mute,
  channelUp,
  channelDown,
  inputNext,
  menu,
  back,
  up,
  down,
  left,
  right,
  select,
  play,
  pause,
  stop,
}

Never _invalid() =>
    throw const FormatException('invalid legacy remote response');
Map<String, dynamic> _object(Object? value) =>
    value is Map<String, dynamic> ? value : _invalid();
String _identity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : _invalid();
int _revision(Object? value) =>
    value is int && value >= 1 && value <= 9223372036854775807
    ? value
    : _invalid();
T _closed<T>(Map<String, dynamic> value, Set<String> keys, T Function() read) {
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    return _invalid();
  }
  return read();
}

LegacyRemoteCommandKey _commandKey(Object? value) => switch (value) {
  'power_toggle' => LegacyRemoteCommandKey.powerToggle,
  'power_on' => LegacyRemoteCommandKey.powerOn,
  'power_off' => LegacyRemoteCommandKey.powerOff,
  'volume_up' => LegacyRemoteCommandKey.volumeUp,
  'volume_down' => LegacyRemoteCommandKey.volumeDown,
  'mute' => LegacyRemoteCommandKey.mute,
  'channel_up' => LegacyRemoteCommandKey.channelUp,
  'channel_down' => LegacyRemoteCommandKey.channelDown,
  'input_next' => LegacyRemoteCommandKey.inputNext,
  'menu' => LegacyRemoteCommandKey.menu,
  'back' => LegacyRemoteCommandKey.back,
  'up' => LegacyRemoteCommandKey.up,
  'down' => LegacyRemoteCommandKey.down,
  'left' => LegacyRemoteCommandKey.left,
  'right' => LegacyRemoteCommandKey.right,
  'select' => LegacyRemoteCommandKey.select,
  'play' => LegacyRemoteCommandKey.play,
  'pause' => LegacyRemoteCommandKey.pause,
  'stop' => LegacyRemoteCommandKey.stop,
  _ => _invalid(),
};

String legacyRemoteCommandWire(LegacyRemoteCommandKey value) => switch (value) {
  LegacyRemoteCommandKey.powerToggle => 'power_toggle',
  LegacyRemoteCommandKey.powerOn => 'power_on',
  LegacyRemoteCommandKey.powerOff => 'power_off',
  LegacyRemoteCommandKey.volumeUp => 'volume_up',
  LegacyRemoteCommandKey.volumeDown => 'volume_down',
  LegacyRemoteCommandKey.mute => 'mute',
  LegacyRemoteCommandKey.channelUp => 'channel_up',
  LegacyRemoteCommandKey.channelDown => 'channel_down',
  LegacyRemoteCommandKey.inputNext => 'input_next',
  LegacyRemoteCommandKey.menu => 'menu',
  LegacyRemoteCommandKey.back => 'back',
  LegacyRemoteCommandKey.up => 'up',
  LegacyRemoteCommandKey.down => 'down',
  LegacyRemoteCommandKey.left => 'left',
  LegacyRemoteCommandKey.right => 'right',
  LegacyRemoteCommandKey.select => 'select',
  LegacyRemoteCommandKey.play => 'play',
  LegacyRemoteCommandKey.pause => 'pause',
  LegacyRemoteCommandKey.stop => 'stop',
};

@immutable
final class LegacyRemoteAuthority {
  const LegacyRemoteAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.routeId,
    required this.homeRevision,
    required this.accountRevision,
    required this.memberRevision,
    required this.sessionRevision,
    required this.routeRevision,
  });

  factory LegacyRemoteAuthority.fromCoreJson(
    Object? json, {
    required String routeId,
    required int sessionRevision,
    required int routeRevision,
  }) {
    final value = _object(json);
    return _closed(
      value,
      const {
        'schemaVersion',
        'coreId',
        'homeId',
        'homeRevision',
        'accountId',
        'accountRevision',
        'memberRevision',
        'sessionFamilyId',
        'active',
        'canControlLegacyRemote',
      },
      () {
        if (value['schemaVersion'] != 1 ||
            value['active'] != true ||
            value['canControlLegacyRemote'] != true) {
          return _invalid();
        }
        return LegacyRemoteAuthority(
          coreId: _identity(value['coreId']),
          homeId: _identity(value['homeId']),
          accountId: _identity(value['accountId']),
          sessionFamilyId: _identity(value['sessionFamilyId']),
          routeId: _identity(routeId),
          homeRevision: _revision(value['homeRevision']),
          accountRevision: _revision(value['accountRevision']),
          memberRevision: _revision(value['memberRevision']),
          sessionRevision: _revision(sessionRevision),
          routeRevision: _revision(routeRevision),
        );
      },
    );
  }

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final String routeId;
  final int homeRevision;
  final int accountRevision;
  final int memberRevision;
  final int sessionRevision;
  final int routeRevision;

  bool get isBounded =>
      [
        coreId,
        homeId,
        accountId,
        sessionFamilyId,
        routeId,
      ].every((value) => RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) &&
      [
        homeRevision,
        accountRevision,
        memberRevision,
        sessionRevision,
        routeRevision,
      ].every((value) => value >= 1);

  Map<String, dynamic> toCoreJson() => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'homeRevision': homeRevision,
    'accountId': accountId,
    'accountRevision': accountRevision,
    'memberRevision': memberRevision,
    'sessionFamilyId': sessionFamilyId,
    'active': true,
    'canControlLegacyRemote': true,
  };

  @override
  bool operator ==(Object other) =>
      other is LegacyRemoteAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      routeId == other.routeId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      memberRevision == other.memberRevision &&
      sessionRevision == other.sessionRevision &&
      routeRevision == other.routeRevision;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    routeId,
    homeRevision,
    accountRevision,
    memberRevision,
    sessionRevision,
    routeRevision,
  );

  @override
  String toString() => 'LegacyRemoteAuthority(redacted)';
}

@immutable
final class LegacyRemoteCommandDefinition {
  const LegacyRemoteCommandDefinition({
    required this.bindingId,
    required this.key,
    required this.maxRepeats,
    required this.maxHoldMs,
  });

  factory LegacyRemoteCommandDefinition.fromJson(Object? json) {
    final value = _object(json);
    return _closed(
      value,
      const {'schemaVersion', 'bindingId', 'key', 'maxRepeats', 'maxHoldMs'},
      () {
        if (value['schemaVersion'] != 1 ||
            value['maxRepeats'] is! int ||
            value['maxHoldMs'] is! int) {
          return _invalid();
        }
        return LegacyRemoteCommandDefinition(
          bindingId: _identity(value['bindingId']),
          key: _commandKey(value['key']),
          maxRepeats: value['maxRepeats'] as int,
          maxHoldMs: value['maxHoldMs'] as int,
        );
      },
    );
  }

  final String bindingId;
  final LegacyRemoteCommandKey key;
  final int maxRepeats;
  final int maxHoldMs;
  bool get isBounded =>
      RegExp(r'^[0-9a-f]{32}$').hasMatch(bindingId) &&
      maxRepeats >= 1 &&
      maxRepeats <= 3 &&
      maxHoldMs >= 0 &&
      maxHoldMs <= 2000;

  @override
  String toString() => 'LegacyRemoteCommandDefinition($key, opaque)';
}

@immutable
final class LegacyRemoteDevice {
  LegacyRemoteDevice({
    required this.authority,
    required this.deviceId,
    required this.name,
    required this.deviceRevision,
    required this.providerType,
    required this.providerId,
    required this.providerRevision,
    required this.bridgeId,
    required this.bridgeRevision,
    required this.protocol,
    required this.profileId,
    required this.profileRevision,
    required this.codeSetId,
    required this.codeSetRevision,
    required this.stored,
    required this.reachable,
    required this.providerVerified,
    required List<LegacyRemoteCommandDefinition> commands,
  }) : commands = List.unmodifiable(commands);

  factory LegacyRemoteDevice.fromCatalogItem(
    Object? json,
    LegacyRemoteAuthority authority,
  ) {
    final item = _object(json);
    return _closed(
      item,
      const {'schemaVersion', 'name', 'device', 'profile'},
      () {
        if (item['schemaVersion'] != 1 || item['name'] is! String) {
          return _invalid();
        }
        final name = (item['name'] as String).trim();
        if (name.isEmpty || name.length > 128) return _invalid();
        final device = _object(item['device']);
        final profile = _object(item['profile']);
        const deviceKeys = {
          'schemaVersion',
          'coreId',
          'homeId',
          'deviceId',
          'revision',
          'providerType',
          'providerId',
          'providerRevision',
          'bridgeId',
          'bridgeRevision',
          'protocol',
          'stored',
          'reachable',
          'providerVerified',
        };
        const profileKeys = {
          'schemaVersion',
          'coreId',
          'homeId',
          'profileId',
          'revision',
          'deviceId',
          'expectedDeviceRevision',
          'providerId',
          'expectedProviderRevision',
          'codeSetId',
          'codeSetRevision',
          'protocol',
          'commands',
        };
        if (device.length != deviceKeys.length ||
            !device.keys.every(deviceKeys.contains) ||
            profile.length != profileKeys.length ||
            !profile.keys.every(profileKeys.contains) ||
            device['schemaVersion'] != 1 ||
            profile['schemaVersion'] != 1 ||
            device['coreId'] != authority.coreId ||
            device['homeId'] != authority.homeId ||
            profile['coreId'] != authority.coreId ||
            profile['homeId'] != authority.homeId) {
          return _invalid();
        }
        final commandsRaw = profile['commands'];
        if (commandsRaw is! List ||
            commandsRaw.isEmpty ||
            commandsRaw.length > 64) {
          return _invalid();
        }
        final commands = commandsRaw
            .map(LegacyRemoteCommandDefinition.fromJson)
            .toList();
        final provider = switch (device['providerType']) {
          'home_assistant' => LegacyRemoteProvider.homeAssistant,
          'isolated_bridge' => LegacyRemoteProvider.isolatedBridge,
          _ => _invalid(),
        };
        final protocol = switch (device['protocol']) {
          'ir' => LegacyRemoteProtocol.ir,
          'rf' => LegacyRemoteProtocol.rf,
          _ => _invalid(),
        };
        if (profile['protocol'] != device['protocol'] ||
            profile['deviceId'] != device['deviceId'] ||
            profile['expectedDeviceRevision'] != device['revision'] ||
            profile['providerId'] != device['providerId'] ||
            profile['expectedProviderRevision'] != device['providerRevision']) {
          return _invalid();
        }
        return LegacyRemoteDevice(
          authority: authority,
          deviceId: _identity(device['deviceId']),
          name: name,
          deviceRevision: _revision(device['revision']),
          providerType: provider,
          providerId: _identity(device['providerId']),
          providerRevision: _revision(device['providerRevision']),
          bridgeId: _identity(device['bridgeId']),
          bridgeRevision: _revision(device['bridgeRevision']),
          protocol: protocol,
          profileId: _identity(profile['profileId']),
          profileRevision: _revision(profile['revision']),
          codeSetId: _identity(profile['codeSetId']),
          codeSetRevision: _revision(profile['codeSetRevision']),
          stored: device['stored'] is bool
              ? device['stored'] as bool
              : _invalid(),
          reachable: device['reachable'] is bool
              ? device['reachable'] as bool
              : _invalid(),
          providerVerified: device['providerVerified'] is bool
              ? device['providerVerified'] as bool
              : _invalid(),
          commands: commands,
        );
      },
    );
  }

  final LegacyRemoteAuthority authority;
  final String deviceId;
  final String name;
  final int deviceRevision;
  final LegacyRemoteProvider providerType;
  final String providerId;
  final int providerRevision;
  final String bridgeId;
  final int bridgeRevision;
  final LegacyRemoteProtocol protocol;
  final String profileId;
  final int profileRevision;
  final String codeSetId;
  final int codeSetRevision;
  final bool stored;
  final bool reachable;
  final bool providerVerified;
  final List<LegacyRemoteCommandDefinition> commands;

  bool get canDispatch => stored && reachable && providerVerified;
  bool get isCoherent =>
      authority.isBounded &&
      [
        deviceId,
        providerId,
        bridgeId,
        profileId,
        codeSetId,
      ].every((value) => RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) &&
      name.trim().isNotEmpty &&
      [
        deviceRevision,
        providerRevision,
        bridgeRevision,
        profileRevision,
        codeSetRevision,
      ].every((value) => value >= 1) &&
      commands.isNotEmpty &&
      commands.length <= 64 &&
      commands.every((value) => value.isBounded) &&
      commands.map((value) => value.key).toSet().length == commands.length &&
      commands.map((value) => value.bindingId).toSet().length ==
          commands.length;

  @override
  String toString() => 'LegacyRemoteDevice($deviceId, secret-free)';
}

@immutable
final class LegacyRemoteCatalog {
  LegacyRemoteCatalog({
    required this.authority,
    required List<LegacyRemoteDevice> devices,
  }) : devices = List.unmodifiable(devices);

  factory LegacyRemoteCatalog.fromJson(
    Object? json, {
    required String routeId,
    required int sessionRevision,
    required int routeRevision,
  }) {
    final value = _object(json);
    return _closed(value, const {'schemaVersion', 'authority', 'items'}, () {
      if (value['schemaVersion'] != 1 || value['items'] is! List) {
        return _invalid();
      }
      final authority = LegacyRemoteAuthority.fromCoreJson(
        value['authority'],
        routeId: routeId,
        sessionRevision: sessionRevision,
        routeRevision: routeRevision,
      );
      final raw = value['items'] as List;
      if (raw.length > 100) return _invalid();
      final devices = raw
          .map((item) => LegacyRemoteDevice.fromCatalogItem(item, authority))
          .toList();
      if (devices.map((value) => value.deviceId).toSet().length !=
              devices.length ||
          devices.any((value) => !value.isCoherent)) {
        return _invalid();
      }
      return LegacyRemoteCatalog(authority: authority, devices: devices);
    });
  }

  final LegacyRemoteAuthority authority;
  final List<LegacyRemoteDevice> devices;
}

@immutable
final class LegacyRemoteCommandPreview {
  const LegacyRemoteCommandPreview({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.providerType,
    required this.providerId,
    required this.providerRevision,
    required this.bridgeId,
    required this.bridgeRevision,
    required this.profileId,
    required this.profileRevision,
    required this.codeSetId,
    required this.codeSetRevision,
    required this.bindingId,
    required this.key,
    required this.repeats,
    required this.holdMs,
    required this.expiresAt,
    required this.confirmationToken,
  });

  factory LegacyRemoteCommandPreview.fromJson(
    Object? json,
    LegacyRemoteAuthority authority,
  ) {
    final value = _object(json);
    const keys = {
      'schemaVersion',
      'requestId',
      'coreId',
      'homeId',
      'homeRevision',
      'accountId',
      'accountRevision',
      'memberRevision',
      'sessionFamilyId',
      'deviceId',
      'deviceRevision',
      'providerType',
      'providerId',
      'providerRevision',
      'bridgeId',
      'bridgeRevision',
      'profileId',
      'profileRevision',
      'codeSetId',
      'codeSetRevision',
      'bindingId',
      'key',
      'repeats',
      'holdMs',
      'expiresAtMs',
      'confirmationToken',
    };
    return _closed(value, keys, () {
      final coreAuthority = authority.toCoreJson();
      for (final key in const [
        'coreId',
        'homeId',
        'homeRevision',
        'accountId',
        'accountRevision',
        'memberRevision',
        'sessionFamilyId',
      ]) {
        if (value[key] != coreAuthority[key]) return _invalid();
      }
      final expires = value['expiresAtMs'];
      if (value['schemaVersion'] != 1 ||
          expires is! int ||
          expires < 0 ||
          value['confirmationToken'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(value['confirmationToken'] as String) ||
          value['repeats'] is! int ||
          value['holdMs'] is! int) {
        return _invalid();
      }
      return LegacyRemoteCommandPreview(
        authority: authority,
        requestId: _identity(value['requestId']),
        deviceId: _identity(value['deviceId']),
        deviceRevision: _revision(value['deviceRevision']),
        providerType: switch (value['providerType']) {
          'home_assistant' => LegacyRemoteProvider.homeAssistant,
          'isolated_bridge' => LegacyRemoteProvider.isolatedBridge,
          _ => _invalid(),
        },
        providerId: _identity(value['providerId']),
        providerRevision: _revision(value['providerRevision']),
        bridgeId: _identity(value['bridgeId']),
        bridgeRevision: _revision(value['bridgeRevision']),
        profileId: _identity(value['profileId']),
        profileRevision: _revision(value['profileRevision']),
        codeSetId: _identity(value['codeSetId']),
        codeSetRevision: _revision(value['codeSetRevision']),
        bindingId: _identity(value['bindingId']),
        key: _commandKey(value['key']),
        repeats: value['repeats'] as int,
        holdMs: value['holdMs'] as int,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
        confirmationToken: value['confirmationToken'] as String,
      );
    });
  }

  final LegacyRemoteAuthority authority;
  final String requestId;
  final String deviceId;
  final int deviceRevision;
  final LegacyRemoteProvider providerType;
  final String providerId;
  final int providerRevision;
  final String bridgeId;
  final int bridgeRevision;
  final String profileId;
  final int profileRevision;
  final String codeSetId;
  final int codeSetRevision;
  final String bindingId;
  final LegacyRemoteCommandKey key;
  final int repeats;
  final int holdMs;
  final DateTime expiresAt;
  final String confirmationToken;

  bool isExactFor(
    LegacyRemoteAuthority expected,
    LegacyRemoteDevice device,
    LegacyRemoteCommandDefinition command,
    DateTime now,
  ) =>
      authority == expected &&
      device.authority == expected &&
      deviceId == device.deviceId &&
      deviceRevision == device.deviceRevision &&
      providerType == device.providerType &&
      providerId == device.providerId &&
      providerRevision == device.providerRevision &&
      bridgeId == device.bridgeId &&
      bridgeRevision == device.bridgeRevision &&
      profileId == device.profileId &&
      profileRevision == device.profileRevision &&
      codeSetId == device.codeSetId &&
      codeSetRevision == device.codeSetRevision &&
      bindingId == command.bindingId &&
      key == command.key &&
      repeats >= 1 &&
      repeats <= command.maxRepeats &&
      holdMs >= 0 &&
      holdMs <= command.maxHoldMs &&
      expiresAt.isAfter(now);

  Map<String, dynamic> toCoreJson() {
    final authorityJson = authority.toCoreJson()
      ..remove('active')
      ..remove('canControlLegacyRemote')
      ..remove('schemaVersion');
    return {
      'schemaVersion': 1,
      'requestId': requestId,
      ...authorityJson,
      'deviceId': deviceId,
      'deviceRevision': deviceRevision,
      'providerType': providerType == LegacyRemoteProvider.homeAssistant
          ? 'home_assistant'
          : 'isolated_bridge',
      'providerId': providerId,
      'providerRevision': providerRevision,
      'bridgeId': bridgeId,
      'bridgeRevision': bridgeRevision,
      'profileId': profileId,
      'profileRevision': profileRevision,
      'codeSetId': codeSetId,
      'codeSetRevision': codeSetRevision,
      'bindingId': bindingId,
      'key': legacyRemoteCommandWire(key),
      'repeats': repeats,
      'holdMs': holdMs,
      'expiresAtMs': expiresAt.millisecondsSinceEpoch,
      'confirmationToken': confirmationToken,
    };
  }

  @override
  String toString() => 'LegacyRemoteCommandPreview($key, redacted)';
}

@immutable
final class LegacyRemoteCommandResult {
  const LegacyRemoteCommandResult({
    required this.preview,
    required this.status,
    required this.deliveryVerified,
    required this.deviceStateVerified,
  });

  factory LegacyRemoteCommandResult.fromJson(
    Object? json,
    LegacyRemoteCommandPreview preview,
  ) {
    final value = _object(json);
    return _closed(
      value,
      const {
        'schemaVersion',
        'requestId',
        'status',
        'reason',
        'deliveryVerified',
        'deviceStateVerified',
        'receipt',
      },
      () {
        if (value['schemaVersion'] != 1 ||
            value['requestId'] != preview.requestId ||
            value['deviceStateVerified'] != false) {
          return _invalid();
        }
        final status = switch (value['status']) {
          'dispatched' => LegacyRemoteDispatchStatus.dispatched,
          'uncertain' => LegacyRemoteDispatchStatus.uncertain,
          _ => _invalid(),
        };
        if (status == LegacyRemoteDispatchStatus.uncertain) {
          if (value['deliveryVerified'] != false ||
              value['receipt'] != null ||
              !{'lost_ack', 'readback_mismatch'}.contains(value['reason'])) {
            return _invalid();
          }
        } else {
          if (value['deliveryVerified'] != true || value['reason'] != null) {
            return _invalid();
          }
          final receipt = _object(value['receipt']);
          const receiptKeys = {
            'schemaVersion',
            'requestId',
            'coreId',
            'homeId',
            'providerId',
            'providerRevision',
            'bridgeId',
            'bridgeRevision',
            'deviceId',
            'deviceRevision',
            'profileId',
            'profileRevision',
            'codeSetId',
            'codeSetRevision',
            'bindingId',
            'key',
            'repeats',
            'holdMs',
            'status',
          };
          final expected = {
            'schemaVersion': 1,
            'requestId': preview.requestId,
            'coreId': preview.authority.coreId,
            'homeId': preview.authority.homeId,
            'providerId': preview.providerId,
            'providerRevision': preview.providerRevision,
            'bridgeId': preview.bridgeId,
            'bridgeRevision': preview.bridgeRevision,
            'deviceId': preview.deviceId,
            'deviceRevision': preview.deviceRevision,
            'profileId': preview.profileId,
            'profileRevision': preview.profileRevision,
            'codeSetId': preview.codeSetId,
            'codeSetRevision': preview.codeSetRevision,
            'bindingId': preview.bindingId,
            'key': legacyRemoteCommandWire(preview.key),
            'repeats': preview.repeats,
            'holdMs': preview.holdMs,
            'status': 'emitted',
          };
          if (receipt.length != receiptKeys.length ||
              !receipt.keys.every(receiptKeys.contains) ||
              receipt.entries.any(
                (entry) => expected[entry.key] != entry.value,
              )) {
            return _invalid();
          }
        }
        return LegacyRemoteCommandResult(
          preview: preview,
          status: status,
          deliveryVerified: value['deliveryVerified'] as bool,
          deviceStateVerified: false,
        );
      },
    );
  }

  final LegacyRemoteCommandPreview preview;
  final LegacyRemoteDispatchStatus status;
  final bool deliveryVerified;
  final bool deviceStateVerified;
  String get requestId => preview.requestId;

  bool isExactFor(LegacyRemoteCommandPreview expected) =>
      identical(preview, expected) &&
      status == LegacyRemoteDispatchStatus.dispatched &&
      deliveryVerified &&
      !deviceStateVerified;

  @override
  String toString() => 'LegacyRemoteCommandResult($status, redacted)';
}
