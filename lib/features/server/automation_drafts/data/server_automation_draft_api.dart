import 'dart:math';

import '../../../core_ha/data/core_ha_api.dart';
import '../../../core_ha/domain/core_ha_models.dart';
import '../../../home_resources/data/home_resources_api.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_automation_draft_models.dart';

final class ServerAutomationDraftApi {
  const ServerAutomationDraftApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/automation-drafts/${context.coreId}/${context.homeId}';

  Future<ServerAutomationDraftSelection> create(String transcript) async {
    await _validateCatalog();
    final selected = await _selectSwitch();
    final target = selected.$1;
    final snapshot = selected.$2;
    final json = serverObject(
      await api.request(
        'POST',
        _root,
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': _requestKey('automation-draft'),
          'transcript': transcript,
          'resourceId': target.id,
          'expectedResourceRevision': snapshot.resourceRevision,
          'expectedAclRevision': snapshot.aclRevision,
          'expectedBindingRevision': snapshot.bindingRevision,
          'expectedServiceRevision': snapshot.serviceRevision,
        },
      ),
    );
    return ServerAutomationDraftSelection(
      draft: _draft(json),
      targetLabel: target.label,
    );
  }

  Future<ServerAutomationDraft> activate(ServerAutomationDraft draft) async {
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/${draft.id}/activation',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': _requestKey('automation-draft-activation'),
          'expectedDraftRevision': draft.revision,
          'confirmed': true,
        },
      ),
    );
    final activated = _draft(json);
    if (activated.id != draft.id ||
        activated.resourceId != draft.resourceId ||
        activated.action != draft.action ||
        !activated.activated ||
        activated.rule == null) {
      throw const LarenorServerException('invalid_response');
    }
    return activated;
  }

  Future<void> _validateCatalog() async {
    final value = serverObject(
      await api.request('GET', '$_root/actions', token: token),
    );
    final actions = value['actions'];
    if (value.length != 4 ||
        value['schemaVersion'] != 1 ||
        value['catalogVersion'] != 'ha-switch-actions-v1' ||
        value['deviceCommandAvailable'] != false ||
        actions is! List ||
        actions.length != 2 ||
        actions[0] != 'turn_on' ||
        actions[1] != 'turn_off') {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<(HomeResourceRecord, CoreHaSnapshot)> _selectSwitch() async {
    String? after, snapshot;
    var seen = 0;
    do {
      final page = await HomeResourcesApi(
        api,
        token,
        context,
      ).list(after: after, snapshot: snapshot, limit: 100);
      snapshot ??= page.snapshot;
      for (final target in page.entries) {
        if (++seen > HomeResourcePage.maximumRecords) {
          throw const LarenorServerException('automation_draft_target_missing');
        }
        if (target.kind != HomeResourceKind.resource || !target.canWrite) {
          continue;
        }
        final homeAssistant = CoreHaApi(
          api,
          token,
          target,
          isCurrent: () => true,
        );
        try {
          final current = await homeAssistant.snapshot();
          if (current.projection.kind == 'switch' &&
              current.projection.commandAvailable) {
            return (target, current);
          }
        } on LarenorServerException catch (error) {
          if (!{'not_found', 'ha_binding_missing'}.contains(error.code)) {
            rethrow;
          }
        } finally {
          homeAssistant.retire();
        }
      }
      after = page.nextAfter;
    } while (after != null);
    throw const LarenorServerException('automation_draft_target_missing');
  }

  ServerAutomationDraft _draft(Map<String, dynamic> json) {
    if (json.length != 1 || !json.containsKey('draft')) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerAutomationDraft.fromJson(json['draft'], context: context);
  }

  static String _requestKey(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix:$value';
  }
}
