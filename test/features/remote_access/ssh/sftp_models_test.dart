import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/ssh/sftp_models.dart';

void main() {
  group('normalizeSftpPath', () {
    test('normalizes absolute and relative paths without escaping root', () {
      expect(normalizeSftpPath('/srv//media/./films'), '/srv/media/films');
      expect(normalizeSftpPath('../music', base: '/srv/media'), '/srv/music');
      expect(normalizeSftpPath('../../..', base: '/srv'), '/');
    });

    test('rejects control characters, backslashes and oversized paths', () {
      for (final value in ['/tmp/\u0000secret', r'/tmp\secret', '/${'x' * 4097}']) {
        expect(() => normalizeSftpPath(value), throwsA(isA<SftpFailure>()));
      }
    });
  });

  test('joinSftpPath accepts one safe UTF-8 filename only', () {
    expect(joinSftpPath('/srv/music', 'Türkçe.flac'), '/srv/music/Türkçe.flac');
    for (final name in ['', '.', '..', 'a/b', r'a\b', 'x' * 256]) {
      expect(() => joinSftpPath('/srv', name), throwsA(isA<SftpFailure>()));
    }
  });
}
