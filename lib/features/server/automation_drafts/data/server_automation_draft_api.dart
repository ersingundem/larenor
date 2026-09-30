import 'dart:math';

import '../../../core_ha/data/core_ha_api.dart';
import '../../../core_ha/domain/core_ha_models.dart';
import '../../../home_resources/data/home_resources_api.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_automation_draft_models.dart';

final class ServerAutomationDraftApi {
  const ServerAutomationDraftApi(
    this.api,
    this.token,
    this.context, {
    this.isCurrent,
  });
  final bool Function()? isCurrent;
  void _current() {
    if (isCurrent?.call() == false) {
      throw const LarenorServerException('cancelled');
    }
  }

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/automation-drafts/${context.coreId}/${context.homeId}';

  Future<ServerAutomationDraftSelection> create(
    String transcript, {
    String? resourceId,
  }) async {
    _current();
    await _validateCatalog();
    final selected = await _selectSwitch(resourceId);
    _current();
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
    _current();
    final result = _draft(json);
    if (result.resourceId != target.id) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerAutomationDraftSelection(
      draft: result,
      targetLabel: target.label,
    );
  }

  Future<ServerAutomationDraft> activate(ServerAutomationDraft draft) async {
    _current();
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
    _current();
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

  Future<List<(HomeResourceRecord, CoreHaSnapshot)>> _targets({
    String? resourceId,
  }) async {
    String? after, snapshot;
    final found = <(HomeResourceRecord, CoreHaSnapshot)>[];
    var seen = 0;
    do {
      _current();
      final page = await HomeResourcesApi(
        api,
        token,
        context,
      ).list(after: after, snapshot: snapshot, limit: 100);
      _current();
      snapshot ??= page.snapshot;
      for (final target in page.entries) {
        if (++seen > HomeResourcePage.maximumRecords) {
          throw const LarenorServerException('automation_draft_target_missing');
        }
        _current();
        if ((resourceId != null && target.id != resourceId) ||
            target.kind != HomeResourceKind.resource ||
            !target.canWrite) {
          continue;
        }
        final homeAssistant = CoreHaApi(
          api,
          token,
          target,
          isCurrent: () => isCurrent?.call() ?? true,
        );
        try {
          final current = await homeAssistant.snapshot();
          _current();
          if (current.projection.kind == 'switch' &&
              current.projection.commandAvailable) {
            found.add((target, current));
            if (found.length > 256) {
              throw const LarenorServerException('capacity_reached');
            }
            if (resourceId != null) return found;
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
    return found;
  }

  Future<List<HomeResourceRecord>> targets() async {
    final found = await _targets();
    if (found.isEmpty) {
      throw const LarenorServerException('automation_draft_target_missing');
    }
    return List.unmodifiable(found.map((entry) => entry.$1));
  }

  Future<(HomeResourceRecord, CoreHaSnapshot)> _selectSwitch(
    String? resourceId,
  ) async {
    final found = await _targets(resourceId: resourceId);
    if (found.isEmpty) {
      throw const LarenorServerException('automation_draft_target_missing');
    }
    if (found.length != 1) {
      throw const LarenorServerException('automation_draft_target_required');
    }
    return found.single;
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
