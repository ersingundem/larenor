import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  late SecureServerSessionStore store;
  final session = ServerSession(
    endpoint: ServerEndpoint('https://synthetic.invalid/prefix'),
    accessToken: 'synthetic_access_token_for_store',
    refreshToken: 'synthetic_refresh_token_for_store',
    expiresAt: DateTime.utc(2026, 9, 5, 12),
    user: const ServerUser(
      id: 'fixture',
      username: 'fixture',
      role: ServerRole.admin,
      mustChangePassword: false,
    ),
  );
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
  });
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = SecureServerSessionStore(storage: storage);
  });

  test('intent, pending pair and bound identity replace the same single secure record', () async {
    await store.write(session.withAuthMutationPending());
    expect((await store.read())?.authMutationPending, isTrue);
    await store.write(session);
    expect((await store.read())?.context, isNull);
    expect((await store.read())?.authMutationPending, isFalse);
    await store.write(session.withContext(context));
    final saved = await storage.readAll();
    expect(saved.keys, [SecureServerSessionStore.key]);
    final record = jsonDecode(saved.values.single) as Map<String, dynamic>;
    expect(record['version'], 2);
    expect(record['context'], context.toJson());
    expect((await store.read())?.context, context);
    await store.write(null);
    expect(await store.read(), isNull);
    expect(await storage.readAll(), isEmpty);
  });

  test(
    'legacy v1 is read without invented context then replaced in place by v2',
    () async {
      final legacy =
          jsonDecode(session.encodeStorage()) as Map<String, dynamic>;
      legacy['version'] = 1;
      legacy.remove('context');
      legacy.remove('authMutationPending');
      FlutterSecureStorage.setMockInitialValues({
        SecureServerSessionStore.key: jsonEncode(legacy),
      });
      final restored = await store.read();
      expect(restored?.context, isNull);
      expect(restored?.authMutationPending, isFalse);
      await store.write(restored!.withContext(context));
      expect((await storage.readAll()).keys, [SecureServerSessionStore.key]);
      expect((await store.read())?.context, context);
    },
  );

  test('malformed v2 intent or context fails without exposing or rewriting its record', () async {
    for (final patch in [
      {'authMutationPending': null},
      {'authMutationPending': 1},
      {'version': 2.0},
      {
        'context': {
          'schemaVersion': true,
          'coreId': 'a' * 32,
          'homeId': 'b' * 32,
        },
      },
      {'unknown': 'synthetic-sensitive-value'},
    ]) {
      final raw = jsonDecode(session.encodeStorage()) as Map<String, dynamic>;
      raw.addAll(patch);
      final encoded = jsonEncode(raw);
      FlutterSecureStorage.setMockInitialValues({
        SecureServerSessionStore.key: encoded,
      });
      await expectLater(
        store.read(),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'fixed code',
            'invalid_session',
          ),
        ),
      );
      expect(await storage.read(key: SecureServerSessionStore.key), encoded);
    }
  });
}
