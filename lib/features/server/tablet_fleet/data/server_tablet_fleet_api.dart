import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_tablet_fleet_models.dart';

class ServerTabletFleetApi {
  const ServerTabletFleetApi(this.api, this.token, this.context);

  final LarenorServerApi api;
  final String token;
  final ServerContext context;

  String get _root =>
      '/tablet-fleet/${context.coreId}/${context.homeId}/devices';

  Future<KioskProfileRolloutPreview> previewRollout({
    required List<ManagedTablet> tablets,
    required int profileRevision,
    required int rolloutPercent,
    bool fullscreen = true,
    int idleTimeoutSeconds = 300,
    String channel = 'stable',
  }) async {
    if (tablets.isEmpty ||
        tablets.length > 256 ||
        tablets.any((tablet) => tablet.context != context) ||
        tablets.map((tablet) => tablet.id).toSet().length != tablets.length ||
        profileRevision < 1 ||
        profileRevision > 9223372036854775807 ||
        rolloutPercent < 1 ||
        rolloutPercent > 100 ||
        idleTimeoutSeconds < 30 ||
        idleTimeoutSeconds > 86400 ||
        !{'stable', 'beta'}.contains(channel)) {
      throw const LarenorServerException('invalid_request');
    }
    final ordered = [...tablets]..sort((a, b) => a.id.compareTo(b.id));
    final targets = [
      for (final tablet in ordered)
        {'deviceId': tablet.id, 'expectedDeviceRevision': tablet.revision},
    ];
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              1,
              channel,
              profileRevision,
              rolloutPercent,
              [fullscreen, idleTimeoutSeconds],
              [
                for (final tablet in ordered) [tablet.id, tablet.revision],
              ],
            ]),
          ),
        )
        .toString();
    final preview = KioskProfileRolloutPreview.fromJson(
      await api.request(
        'POST',
        '/tablet-fleet/${context.coreId}/${context.homeId}/profiles/dry-run',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestDigest': digest,
          'channel': channel,
          'profileRevision': profileRevision,
          'rolloutPercent': rolloutPercent,
          'settings': {
            'fullscreen': fullscreen,
            'idleTimeoutSeconds': idleTimeoutSeconds,
          },
          'targets': targets,
        },
      ),
    );
    if (preview.context != context ||
        preview.requestDigest != digest ||
        preview.profileRevision != profileRevision ||
        preview.rolloutPercent != rolloutPercent ||
        preview.devices.length != ordered.length) {
      throw const LarenorServerException('invalid_response');
    }
    for (var index = 0; index < ordered.length; index++) {
      final expected = ordered[index];
      final observed = preview.devices[index];
      final differences = <String>[
        if (expected.clientVersion != preview.release.versionName)
          'applicationVersion',
        if (expected.appliedProfileRevision != profileRevision)
          'profileRevision',
      ];
      final selected =
          int.parse(
                sha256
                    .convert(
                      utf8.encode('${preview.profileSeal}:${expected.id}'),
                    )
                    .toString()
                    .substring(0, 8),
                radix: 16,
              ) %
              100 <
          rolloutPercent;
      final state = switch (expected.state) {
        TabletFleetState.revoked => KioskRolloutDeviceState.revoked,
        TabletFleetState.active
            when differences.contains('applicationVersion') =>
          KioskRolloutDeviceState.appUpdateRequired,
        TabletFleetState.active when differences.isEmpty =>
          KioskRolloutDeviceState.current,
        TabletFleetState.active when selected => KioskRolloutDeviceState.ready,
        TabletFleetState.active => KioskRolloutDeviceState.deferred,
      };
      if (observed.deviceId != expected.id ||
          observed.deviceRevision != expected.revision ||
          observed.appliedProfileRevision != expected.appliedProfileRevision ||
          observed.desiredProfileRevision != expected.desiredProfileRevision ||
          observed.state != state ||
          !listEquals(observed.differences, differences)) {
        throw const LarenorServerException('invalid_response');
      }
    }
    return preview;
  }

  Future<List<ManagedTablet>> list() async {
    final result = ManagedTabletList.fromJson(
      await api.request('GET', _root, token: token),
    );
    if (result.context != context) {
      throw const LarenorServerException('invalid_response');
    }
    return result.tablets;
  }

  /// Client-side registration intentionally exposes standard mode only.
  /// Device Owner registration needs a future native proof adapter; the UI
  /// never turns a user choice into a privileged capability claim.
  Future<ManagedTablet> registerStandard({
    required String registrationId,
    required String name,
    required String clientVersion,
    required int appliedProfileRevision,
  }) => _record(
    api.request(
      'POST',
      _root,
      token: token,
      body: {
        'schemaVersion': 1,
        'registrationId': _id(registrationId),
        'name': _name(name),
        'platform': 'android',
        'managementMode': 'standard',
        'clientVersion': _version(clientVersion),
        'appliedProfileRevision': _revision(appliedProfileRevision),
      },
    ),
    expectedId: registrationId,
    expectedMode: TabletManagementMode.standard,
  );

  Future<ManagedTablet> heartbeat(
    ManagedTablet tablet, {
    required String clientVersion,
    required int appliedProfileRevision,
  }) => _record(
    api.request(
      'POST',
      '$_root/${_id(tablet.id)}/heartbeat',
      token: token,
      body: {
        'schemaVersion': 1,
        'expectedRevision': tablet.revision,
        'clientVersion': _version(clientVersion),
        'appliedProfileRevision': _revision(appliedProfileRevision),
      },
    ),
    previous: tablet,
    expectedRevision: tablet.revision,
  );

  Future<ManagedTablet> updateProfile(
    ManagedTablet tablet,
    int desiredProfileRevision,
  ) async {
    final updated = await _record(
      api.request(
        'PUT',
        '$_root/${_id(tablet.id)}/profile',
        token: token,
        body: {
          'schemaVersion': 1,
          'expectedRevision': tablet.revision,
          'desiredProfileRevision': _revision(desiredProfileRevision),
        },
      ),
      previous: tablet,
      expectedRevision: tablet.revision + 1,
    );
    if (updated.desiredProfileRevision != desiredProfileRevision ||
        updated.appliedProfileRevision != tablet.appliedProfileRevision) {
      throw const LarenorServerException('invalid_response');
    }
    final readback = await _find(tablet.id);
    if (!_sameTablet(updated, readback)) {
      throw const LarenorServerException('invalid_response');
    }
    return readback;
  }

  Future<ManagedTablet> revoke(ManagedTablet tablet) async {
    await api.request(
      'DELETE',
      '$_root/${_id(tablet.id)}',
      token: token,
      queryParameters: {'expectedRevision': '${tablet.revision}'},
      allowEmpty: true,
    );
    final readback = await _find(tablet.id);
    if (readback.state != TabletFleetState.revoked ||
        readback.revision != tablet.revision + 1) {
      throw const LarenorServerException('invalid_response');
    }
    return readback;
  }

  Future<ManagedTabletCommand> issueVerified(
    ManagedTablet tablet,
    TabletCommandKind command, {
    required String requestKey,
    required double expiresAt,
  }) async {
    if (tablet.context != context ||
        tablet.state != TabletFleetState.active ||
        !tablet.supports(command) ||
        !expiresAt.isFinite ||
        expiresAt <= 0) {
      throw const LarenorServerException('invalid_request');
    }
    final body = {
      'schemaVersion': 1,
      'expectedDeviceRevision': tablet.revision,
      'expectedPolicyRevision': tablet.desiredProfileRevision,
      'expiresAt': expiresAt,
      'requestKey': _requestKey(requestKey),
      'command': command.name,
    };
    final path = '$_root/${tablet.id}/commands';
    final issued = await _command(
      api.request('POST', path, token: token, body: body),
      expected: command,
    );
    // requestKey makes this explicit second POST a readback of the same Core
    // journal entry. It never creates a second command.
    final readback = await _command(
      api.request('POST', path, token: token, body: body),
      expected: command,
    );
    if (!_sameCommandAuthority(issued, readback)) {
      throw const LarenorServerException('invalid_response');
    }
    if (readback.policyRevision != tablet.desiredProfileRevision ||
        readback.expiresAt != expiresAt) {
      throw const LarenorServerException('invalid_response');
    }
    if (readback.state == TabletCommandState.expired ||
        readback.result == TabletCommandResult.expired) {
      throw const LarenorServerException('tablet_command_expired');
    }
    return readback;
  }

  Future<ManagedTabletCommandPage> poll(
    ManagedTablet tablet, {
    required int after,
    int limit = 20,
  }) async {
    if (tablet.context != context ||
        tablet.state != TabletFleetState.active ||
        after < 0 ||
        limit < 1 ||
        limit > 50) {
      throw const LarenorServerException('invalid_request');
    }
    final page = ManagedTabletCommandPage.fromJson(
      await api.request(
        'POST',
        '$_root/${tablet.id}/commands/poll',
        token: token,
        body: {
          'schemaVersion': 1,
          'expectedDeviceRevision': tablet.revision,
          'expectedPolicyRevision': tablet.desiredProfileRevision,
          'after': after,
          'limit': limit,
        },
      ),
    );
    if (page.tabletRevision != tablet.revision ||
        page.commands.any(
          (item) =>
              item.sequence <= after ||
              item.policyRevision != tablet.desiredProfileRevision ||
              item.state == TabletCommandState.expired ||
              item.result == TabletCommandResult.expired,
        )) {
      throw const LarenorServerException('invalid_response');
    }
    return page;
  }

  Future<ManagedTabletCommand> completeVerified(
    ManagedTablet tablet,
    ManagedTabletCommand command,
    TabletCommandResult result, {
    required int appliedProfileRevision,
  }) async {
    if (tablet.context != context ||
        tablet.state != TabletFleetState.active ||
        command.state == TabletCommandState.pending ||
        command.state == TabletCommandState.expired ||
        command.result == TabletCommandResult.expired ||
        result == TabletCommandResult.expired ||
        command.policyRevision != tablet.desiredProfileRevision ||
        appliedProfileRevision > tablet.desiredProfileRevision) {
      throw const LarenorServerException('invalid_request');
    }
    final body = {
      'schemaVersion': 1,
      'expectedDeviceRevision': tablet.revision,
      'expectedPolicyRevision': tablet.desiredProfileRevision,
      'sequence': command.sequence,
      'result': result.name,
      'appliedProfileRevision': _revision(appliedProfileRevision),
    };
    final path = '$_root/${tablet.id}/commands/${command.id}/complete';
    final completed = await _command(
      api.request('POST', path, token: token, body: body),
      expected: command.kind,
    );
    final readback = await _command(
      api.request('POST', path, token: token, body: body),
      expected: command.kind,
    );
    if (!completed.sameReceipt(readback) ||
        readback.id != command.id ||
        readback.sequence != command.sequence ||
        readback.state != TabletCommandState.completed ||
        readback.result != result) {
      throw const LarenorServerException('invalid_response');
    }
    return readback;
  }

  Future<ManagedTablet> _find(String id) async {
    final matches = (await list()).where((item) => item.id == id).toList();
    if (matches.length != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return matches.single;
  }

  Future<ManagedTablet> _record(
    Future<Map<String, dynamic>?> pending, {
    String? expectedId,
    TabletManagementMode? expectedMode,
    ManagedTablet? previous,
    int? expectedRevision,
  }) async {
    final json = serverObject(await pending);
    if (json.length != 1 || !json.containsKey('tablet')) {
      throw const LarenorServerException('invalid_response');
    }
    final value = ManagedTablet.fromJson(json['tablet']);
    if (value.context != context ||
        (expectedId != null && value.id != expectedId) ||
        (expectedMode != null && value.mode != expectedMode) ||
        (previous != null && !previous.sameAuthority(value)) ||
        (expectedRevision != null && value.revision != expectedRevision)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<ManagedTabletCommand> _command(
    Future<Map<String, dynamic>?> pending, {
    required TabletCommandKind expected,
  }) async {
    final json = serverObject(await pending);
    if (json.length != 1 || !json.containsKey('command')) {
      throw const LarenorServerException('invalid_response');
    }
    final command = ManagedTabletCommand.fromJson(json['command']);
    if (command.kind != expected) {
      throw const LarenorServerException('invalid_response');
    }
    return command;
  }

  static bool _sameTablet(ManagedTablet left, ManagedTablet right) =>
      left.sameAuthority(right) &&
      left.revision == right.revision &&
      left.name == right.name &&
      left.mode == right.mode &&
      left.clientVersion == right.clientVersion &&
      left.desiredProfileRevision == right.desiredProfileRevision &&
      left.appliedProfileRevision == right.appliedProfileRevision &&
      left.state == right.state &&
      left.profileState == right.profileState &&
      left.lastSeenAt == right.lastSeenAt;

  static bool _sameCommandAuthority(
    ManagedTabletCommand left,
    ManagedTabletCommand right,
  ) =>
      left.id == right.id &&
      left.sequence == right.sequence &&
      left.kind == right.kind &&
      left.requiredMode == right.requiredMode &&
      left.policyRevision == right.policyRevision &&
      left.expiresAt == right.expiresAt &&
      left.createdAt == right.createdAt;

  static String _id(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static int _revision(int value) {
    if (value < 1 || value > 9223372036854775807) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _name(String value) {
    if (value.trim() != value ||
        value.isEmpty ||
        value.length > 80 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _version(String value) {
    if (!RegExp(r'^[0-9A-Za-z.+_-]{1,64}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _requestKey(String value) {
    if (!RegExp(r'^[A-Za-z0-9._:-]{16,128}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  @override
  String toString() => 'ServerTabletFleetApi';
}
