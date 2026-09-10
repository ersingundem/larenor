import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/ssh/ssh_key_parser.dart';
// Test-only synthetic keys; pointycastle is pinned through dartssh2.
// ignore: depend_on_referenced_packages
import 'package:pointycastle/export.dart' as pc;

void main() {
  late OpenSSHEd25519KeyPair ed25519;
  late String pem;
  late String encrypted;
  late String costlyEncrypted;
  const phrase = '  synthetic test phrase  ';

  setUpAll(() async {
    final seed = Uint8List.fromList(List.generate(32, (i) => i));
    final pair = await crypto.Ed25519().newKeyPairFromSeed(seed);
    final public = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    ed25519 = OpenSSHEd25519KeyPair(
      public,
      Uint8List.fromList([...seed, ...public]),
      'synthetic test key; never used for authentication',
    );
    pem = ed25519.toPem();
    encrypted = ed25519.toPem(passphrase: phrase, rounds: 1);
    final container = OpenSSHKeyPairs.decode(SSHPem.decode(encrypted).content);
    costlyEncrypted = OpenSSHKeyPairs(
      cipherName: container.cipherName,
      kdfName: container.kdfName,
      kdfOptions: OpenSSHBcryptKdfOptions(
        (container.kdfOptions! as OpenSSHBcryptKdfOptions).salt,
        0x7fffffff,
      ),
      publicKeys: container.publicKeys,
      privateKeyBlob: container.privateKeyBlob,
    ).toPem();
  });

  test('transferred Ed25519, RSA and ECDSA keys can sign locally', () async {
    final random = pc.FortunaRandom()
      ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (i) => i))));
    final generator = pc.RSAKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 32),
          random,
        ),
      );
    final generated = generator.generateKeyPair();
    final rsa = generated.privateKey;
    final curve = pc.ECCurve_secp256r1();
    final scalar = BigInt.from(42);
    final originals = <SSHKeyPair>[
      ed25519,
      OpenSSHRsaKeyPair(
        rsa.modulus!,
        generated.publicKey.exponent!,
        rsa.privateExponent!,
        rsa.q!.modInverse(rsa.p!),
        rsa.p!,
        rsa.q!,
        'synthetic test RSA',
      ),
      OpenSSHEcdsaKeyPair(
        'nistp256',
        (curve.G * scalar)!.getEncoded(false),
        scalar,
        'synthetic test ECDSA',
      ),
    ];
    for (final original in originals) {
      final parsed = (await SshKeyParseTask(original.toPem()).result).single;
      expect(parsed.toPublicKey().encode(), original.toPublicKey().encode());
      final signature = parsed.sign(Uint8List.fromList([1, 2, 3]));
      expect(SSHSignature.getType(signature.encode()), original.type);
    }
  });

  test('encrypted key preserves meaningful passphrase whitespace', () async {
    final parsed = await SshKeyParseTask(encrypted, passphrase: phrase).result;
    expect(
      parsed.single.toPublicKey().encode(),
      ed25519.toPublicKey().encode(),
    );
  });

  test('missing and wrong passphrases fail without leaking them', () async {
    for (final passphrase in ['', 'wrong synthetic phrase']) {
      await expectLater(
        SshKeyParseTask(encrypted, passphrase: passphrase).result,
        throwsA(_failure('invalid_key')),
      );
    }
  });

  test('unsupported PEM formats return a static failure', () async {
    final unsupported = SSHPem('PRIVATE KEY', {}, Uint8List(0)).encode();
    await expectLater(
      SshKeyParseTask(unsupported).result,
      throwsA(_failure('unsupported_key')),
    );
  });

  test('malformed PEM and private parser errors are redacted', () async {
    final malformed = pem.replaceFirst('-----END', 'private-input-END');
    await expectLater(
      SshKeyParseTask(malformed, passphrase: 'private-input-phrase').result,
      throwsA(
        _failure('invalid_key').having(
          (e) => e.toString(),
          'redacted description',
          'SshKeyParseException(invalid_key)',
        ),
      ),
    );
  });

  test('PEM limit is 32 KiB including UTF-8 bytes', () async {
    final exact = '$pem${' ' * (32768 - utf8.encode(pem).length)}';
    expect(await SshKeyParseTask(exact).result, hasLength(1));
    for (final oversized in ['$exact ', 'ğ' * 16385]) {
      await expectLater(
        SshKeyParseTask(oversized).result,
        throwsA(_failure('input_too_large')),
      );
    }
  });

  test('passphrase limit is 1024 UTF-8 bytes', () async {
    final exact = 'ğ' * 512;
    final protected = ed25519.toPem(passphrase: exact, rounds: 1);
    expect(
      await SshKeyParseTask(protected, passphrase: exact).result,
      hasLength(1),
    );
    for (final oversized in ['$exact ', 'x' * 1025]) {
      await expectLater(
        SshKeyParseTask(pem, passphrase: oversized).result,
        throwsA(_failure('input_too_large')),
      );
    }
  });

  test('empty input fails as invalid key', () async {
    await expectLater(
      SshKeyParseTask('').result,
      throwsA(_failure('invalid_key')),
    );
  });

  test('cancellation before isolate startup is idempotent', () async {
    final task = SshKeyParseTask(pem);
    final expectation = expectLater(
      task.result,
      throwsA(_failure('cancelled')),
    );
    task.cancel();
    task.cancel();
    await expectation;
  });

  test(
    'expensive KDF deadline leaves the caller event loop responsive',
    () async {
      final task = SshKeyParseTask(
        costlyEncrypted,
        passphrase: phrase,
        timeout: const Duration(milliseconds: 150),
      );
      final expectation = expectLater(
        task.result,
        throwsA(_failure('timed_out')),
      );
      var timerRan = false;
      await Future<void>.delayed(const Duration(milliseconds: 30), () {
        timerRan = true;
      });
      expect(timerRan, isTrue);
      await expectation;
      expect(await SshKeyParseTask(pem).result, hasLength(1));
    },
  );

  test('expensive KDF can be cancelled during work', () async {
    final task = SshKeyParseTask(costlyEncrypted, passphrase: phrase);
    final expectation = expectLater(
      task.result,
      throwsA(_failure('cancelled')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    task.cancel();
    await expectation;
    expect(await SshKeyParseTask(pem).result, hasLength(1));
  });

  test(
    'completed task remains successful and zero deadline never parses',
    () async {
      final task = SshKeyParseTask(pem, passphrase: '');
      final keys = await task.result;
      task.cancel();
      expect(await task.result, same(keys));
      await expectLater(
        SshKeyParseTask(pem, timeout: Duration.zero).result,
        throwsA(_failure('timed_out')),
      );
    },
  );
}

TypeMatcher<SshKeyParseException> _failure(String code) =>
    isA<SshKeyParseException>().having((e) => e.code, 'code', code);
