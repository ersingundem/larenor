import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_provider_setup_models.dart';

final class ServerMusicProviderSetupApi {
  const ServerMusicProviderSetupApi(this.api, this.token);

  static const root = '/admin/media/music-assistant/providers';

  final LarenorServerApi api;
  final String token;

  Future<ServerMusicProviderSetupCapabilities> capabilities() async =>
      ServerMusicProviderSetupCapabilities.fromJson(
        await api.request('GET', '$root/capabilities', token: token),
      );

  Future<ServerMusicProviderSetup> create(
    ServerMusicProviderSetupIntent intent,
  ) async {
    final value = _setup(
      await api.request('POST', root, token: token, body: intent.toJson()),
    );
    if (!intent.accepts(value)) _invalidResponse();
    return value;
  }

  Future<ServerMusicProviderSetup> get(
    String id, {
    ServerMusicProviderSetup? previous,
  }) async {
    _id(id);
    final value = _setup(await api.request('GET', '$root/$id', token: token));
    if (value.id != id) _invalidResponse();
    if (previous != null) _continuity(previous, value, changed: false);
    return value;
  }

  Future<ServerMusicProviderSetup> submit({
    required ServerMusicProviderSetup previous,
    required String stepId,
    required ServerMusicProviderSetupSubmission submission,
  }) async {
    if (previous.interaction !=
            ServerMusicProviderSetupInteraction.submitForm ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,79}$').hasMatch(stepId)) {
      _invalidRequest();
    }
    submission.validateAgainst(previous.fields);
    return _mutation(
      previous,
      '/responses',
      body: {
        'expectedRevision': previous.revision,
        'stepId': stepId,
        'values': submission.encodeForRequest(),
      },
    );
  }

  Future<ServerMusicProviderSetup> resume(
    ServerMusicProviderSetup previous,
  ) async {
    if (previous.interaction !=
        ServerMusicProviderSetupInteraction.openExternal) {
      _invalidRequest();
    }
    return _mutation(previous, '/resume');
  }

  Future<ServerMusicProviderSetup> retry(
    ServerMusicProviderSetup previous,
  ) async {
    if (previous.nextAction != ServerMusicProviderSetupNextAction.retry ||
        previous.interaction != null) {
      _invalidRequest();
    }
    return _mutation(previous, '/retry');
  }

  Future<ServerMusicProviderSetup> cancel(
    ServerMusicProviderSetup previous,
  ) async {
    if (!{
      ServerMusicProviderSetupState.queued,
      ServerMusicProviderSetupState.actionRequired,
      ServerMusicProviderSetupState.needsAttention,
    }.contains(previous.state)) {
      _invalidRequest();
    }
    return _mutation(previous, '/cancel');
  }

  Future<ServerMusicProviderSetup> _mutation(
    ServerMusicProviderSetup previous,
    String suffix, {
    Map<String, dynamic>? body,
  }) async {
    final value = _setup(
      await api.request(
        'POST',
        '$root/${previous.id}$suffix',
        token: token,
        body: body ?? {'expectedRevision': previous.revision},
      ),
    );
    _continuity(previous, value, changed: true);
    return value;
  }

  ServerMusicProviderSetup _setup(Object? response) {
    final map = _exact(response, {'setup'});
    return ServerMusicProviderSetup.fromJson(map['setup']);
  }

  void _continuity(
    ServerMusicProviderSetup previous,
    ServerMusicProviderSetup value, {
    required bool changed,
  }) {
    if (!previous.sameIdentity(value) ||
        (changed
            ? value.revision <= previous.revision
            : value.revision < previous.revision) ||
        value.updatedAt.isBefore(previous.updatedAt)) {
      _invalidResponse();
    }
  }

  Map<String, dynamic> _exact(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      _invalidResponse();
    }
    return value;
  }

  void _id(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) _invalidRequest();
  }

  Never _invalidRequest() =>
      throw const LarenorServerException('invalid_request');
  Never _invalidResponse() =>
      throw const LarenorServerException('invalid_response');

  @override
  String toString() => 'ServerMusicProviderSetupApi';
}
