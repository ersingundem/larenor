import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/family_board_models.dart';
import 'family_board_controller.dart';

final class FamilyBoardApi implements FamilyBoardGateway {
  const FamilyBoardApi(this._api, this._token, this._binding);
  final LarenorServerApi _api;
  final String _token;
  final FamilyBoardBinding _binding;
  String get _root =>
      '/family-boards/${_binding.coreId}/${_binding.homeId}/${_binding.boardId}';

  @override
  Future<FamilyBoardSnapshot> read(FamilyBoardBinding authority) async {
    _target(authority);
    return FamilyBoardSnapshot.fromJson(await _request('GET', _root), _binding);
  }

  @override
  Future<FamilyBoardDelta> delta(
    FamilyBoardBinding authority, {
    required int afterSequence,
  }) async {
    _target(authority);
    if (afterSequence < 0 || afterSequence > 9223372036854775807) {
      throw const FamilyBoardException('invalid_request');
    }
    return FamilyBoardDelta.fromJson(
      await _request(
        'POST',
        '$_root/delta',
        body: {
          'schemaVersion': 1,
          ..._authorityExpectations(),
          'afterSequence': afterSequence,
          'limit': 100,
        },
      ),
      _binding,
      expectedAfter: afterSequence,
    );
  }

  @override
  Future<FamilyBoardReceipt> mutate(
    FamilyBoardBinding authority,
    FamilyBoardCommand command,
  ) async {
    _target(authority);
    final receipt = FamilyBoardReceipt.fromJson(
      await _request(
        'POST',
        '$_root/commands',
        body: {...command.toJson(), ..._authorityExpectations()},
      ),
      command,
    );
    if (receipt.boardId != _binding.boardId) {
      throw const FamilyBoardException('invalid_response');
    }
    return receipt;
  }

  Map<String, Object> _authorityExpectations() => {
    'expectedHomeRevision': _binding.homeRevision,
    'expectedAccountRevision': _binding.accountRevision,
    'expectedMemberRevision': _binding.memberRevision,
    'expectedSessionFamilyId': _binding.sessionFamilyId,
  };

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      return await _api.request(method, path, token: _token, body: body);
    } on LarenorServerException catch (error) {
      throw FamilyBoardException(error.code);
    }
  }

  void _target(FamilyBoardBinding value) {
    if (!_binding.active || value != _binding) {
      throw const FamilyBoardException('cancelled');
    }
  }
}
