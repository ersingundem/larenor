import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_provider_preview.dart';

final class _Storage extends FlutterSecureStorage {
  _Storage(this.values, {this.afterRead});

  final Map<String, String> values;
  final void Function(int reads)? afterRead;
  int reads = 0;
  final keys = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    keys.add(key);
    final result = values[key];
    afterRead?.call(++reads);
    return result;
  }
}

const _valid = {
  'jellyfin_base_url': 'https://private-jellyfin.invalid/root',
  'jellyfin_user_id': 'private-user-id',
  'jellyfin_access_token': 'private-access-token',
};

void main() {
  test(
    'previews a complete legacy provider without exposing credentials',
    () async {
      final storage = _Storage(Map.of(_valid));
      final preview = await LegacyJellyfinProviderPreviewReader(
        storage: storage,
      ).read(isCurrent: () => true);

      expect(preview?.provider, LegacyMediaProvider.jellyfin);
      expect(preview?.requiresCredentialReentry, isTrue);
      expect(preview.toString(), 'Legacy media provider preview');
      for (final secret in _valid.values) {
        expect(preview.toString(), isNot(contains(secret)));
      }
      expect(storage.keys, [
        'jellyfin_connection_pending_v1',
        'jellyfin_base_url',
        'jellyfin_user_id',
        'jellyfin_access_token',
      ]);
      expect(storage.keys, isNot(contains('jellyfin_device_id')));
    },
  );

  test('does not publish incomplete, invalid or unbounded tuples', () async {
    final invalid = <Map<String, String>>[
      {..._valid}..remove('jellyfin_access_token'),
      {..._valid, 'jellyfin_base_url': 'file:///private/media'},
      {..._valid, 'jellyfin_base_url': 'https://user:pass@example.invalid'},
      {..._valid, 'jellyfin_base_url': 'https://example.invalid/?token=secret'},
      {..._valid, 'jellyfin_base_url': 'https://example.invalid/#private'},
      {..._valid, 'jellyfin_user_id': ''},
      {..._valid, 'jellyfin_user_id': 'x' * 257},
      {..._valid, 'jellyfin_access_token': ''},
      {..._valid, 'jellyfin_access_token': 'x' * 4097},
    ];

    for (final fields in invalid) {
      expect(
        await LegacyJellyfinProviderPreviewReader(storage: _Storage(fields))
            .read(isCurrent: () => true),
        isNull,
      );
    }
  });

  test(
    'pending credential mutation fails closed with a static error',
    () async {
      final fields = {
        ..._valid,
        'jellyfin_connection_pending_v1': 'private-pending-marker',
      };

      await expectLater(
        LegacyJellyfinProviderPreviewReader(storage: _Storage(fields))
            .read(isCurrent: () => true),
        throwsA(
          isA<DirectHomeAccessException>()
              .having((error) => error.code, 'code', 'pending_mutation')
              .having(
                (error) => error.toString(),
                'safe error',
                isNot(contains('private-pending-marker')),
              ),
        ),
      );
    },
  );

  test('authority loss during secure reads retires the preview', () async {
    var current = true;
    final storage = _Storage(
      Map.of(_valid),
      afterRead: (reads) {
        if (reads == 2) current = false;
      },
    );

    await expectLater(
      LegacyJellyfinProviderPreviewReader(storage: storage)
          .read(isCurrent: () => current),
      throwsStateError,
    );
    expect(
      storage.reads,
      4,
      reason: 'the record read is awaited, then retired',
    );
  });
}
