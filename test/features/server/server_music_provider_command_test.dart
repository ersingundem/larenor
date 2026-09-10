import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_provider_commands/domain/server_music_provider_command_models.dart';

import 'server_music_provider_command_test_support.dart';

void main() {
  test('preview and blocked command parse exact secret-free revisions', () {
    final preview = ServerMusicProviderCommandPreview.fromJson(
      providerCommandPreviewJson(),
    );
    expect(preview.effectAvailable, isFalse);
    expect(preview.command, 'disable');
    final command = ServerMusicProviderCommand.fromJson(
      providerCommandJson(requestId: 'f' * 32),
    );
    expect(command.state, 'blocked');
    expect(command.providerRevision, 3);
  });

  test('secret shaped and internally inconsistent responses fail closed', () {
    for (final value in [
      {...providerCommandPreviewJson(), 'token': 'secret'},
      {...providerCommandPreviewJson(), 'effectAvailable': true},
      {
        ...providerCommandJson(requestId: 'f' * 32),
        'state': 'succeeded',
      },
    ]) {
      expect(
        () => value.containsKey('planHash')
            ? ServerMusicProviderCommandPreview.fromJson(value)
            : ServerMusicProviderCommand.fromJson(value),
        throwsA(isA<Exception>()),
      );
    }
  });
}
