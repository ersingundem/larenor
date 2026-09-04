import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';

void main() {
  Map<String, dynamic> document(Object groups) => {
    'version': 1,
    'createdAt': '2026-09-05T00:00:00Z',
    'groups': groups,
  };

  final invalid = <String, Object>{
    'PIN included in settings': {
      'settings': {'settings_pin': 'fixture-secret'},
    },
    'unknown preference key': {
      'settings': {'custom': true},
    },
    'invalid preference type': {
      'settings': {'appearance': true},
    },
    'invalid preference range': {
      'settings': {'night_start_minutes': 1500},
    },
    'unknown optional service': {
      'settings': {
        'enabled_services': ['unknown'],
      },
    },
    'partial credential record': {
      'connections': {
        'ha': {'token': 'fixture-secret'},
      },
    },
    'URL credentials': {
      'connections': {
        'ha': {
          'baseUrl': 'https://user:fixture-secret@example.test',
          'token': 'fixture-secret',
        },
      },
    },
    'URL query secret': {
      'connections': {
        'ha': {
          'baseUrl': 'https://example.test?token=fixture-secret',
          'token': 'fixture-secret',
        },
      },
    },
    'non-HTTP service URL': {
      'connections': {
        'ha': {'baseUrl': 'file:///private/config', 'token': 'fixture-secret'},
      },
    },
    'unknown service': {
      'connections': {
        'unknown': {
          'baseUrl': 'https://example.test',
          'token': 'fixture-secret',
        },
      },
    },
    'runtime Jellyfin identity': {
      'connections': {
        'jellyfin': {
          'baseUrl': 'https://example.test',
          'userId': 'user',
          'accessToken': 'fixture-secret',
          'deviceId': 'old',
        },
      },
    },
    'dashboard injected fields': {
      'dashboard': {'rooms': [], 'settings_pin': 'fixture-secret'},
    },
    'duplicate room IDs': {
      'dashboard': {
        'rooms': [
          {'id': 'r', 'name': 'A'},
          {'id': 'r', 'name': 'B'},
        ],
      },
    },
    'entity ID injection': {
      'dashboard': {
        'favoriteEntityIds': ['light.good/../../config'],
      },
    },
    'webview unsafe URL': {
      'dashboard': {
        'tiles': [
          {
            'id': 't',
            'type': 'webview',
            'x': 0,
            'y': 0,
            'width': 2,
            'height': 2,
            'url': 'javascript:alert(1)',
          },
        ],
      },
    },
    'unsupported tile type': {
      'dashboard': {
        'tiles': [
          {
            'id': 't',
            'type': 'unknown',
            'x': 0,
            'y': 0,
            'width': 2,
            'height': 2,
          },
        ],
      },
    },
    'negative tile width': {
      'dashboard': {
        'tiles': [
          {
            'id': 't',
            'type': 'webview',
            'x': 0,
            'y': 0,
            'width': -2,
            'height': 2,
          },
        ],
      },
    },
    'proxmox host injection': {
      'connections': {
        'proxmox': {
          'host': 'good.test/@bad.test',
          'port': '8006',
          'username': 'root',
          'realm': 'pam',
          'password': 'fixture-secret',
          'allowSelfSigned': 'true',
        },
      },
    },
    'proxmox port outside range': {
      'connections': {
        'proxmox': {
          'host': 'good.test',
          'port': '99999',
          'username': 'root',
          'realm': 'pam',
          'password': 'fixture-secret',
          'allowSelfSigned': 'true',
        },
      },
    },
  };
  for (final entry in invalid.entries) {
    test('${entry.key} rejects the whole snapshot without exposing values', () {
      expect(
        () => BackupSnapshot.fromJson(document(entry.value)),
        throwsA(
          isA<BackupValidationException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains('fixture-secret')),
          ),
        ),
      );
    });
  }

  test(
    'all groups are validated even if credentials would later be deselected',
    () {
      expect(
        () => BackupSnapshot.fromJson(
          document({
            'settings': {'appearance': 'dark'},
            'connections': {
              'ha': {'token': 'fixture-secret'},
            },
          }),
        ),
        throwsA(isA<BackupValidationException>()),
      );
    },
  );

  test('large payload cannot bypass size limit with otherwise valid shape', () {
    expect(
      () => BackupSnapshot.fromJson(
        document({
          'settings': {'appearance': 'a' * (maxBackupPlaintextBytes + 1)},
        }),
      ),
      throwsA(isA<BackupValidationException>()),
    );
  });

  test('version is exact, empty groups are rejected, unknown root keys are rejected', () {
    final invalidVersion = document({'settings': {}})..['version'] = 1.0;
    expect(
      () => BackupSnapshot.fromJson(invalidVersion),
      throwsA(isA<BackupValidationException>()),
    );
    expect(
      () => BackupSnapshot.fromJson(document({})),
      throwsA(isA<BackupValidationException>()),
    );
    expect(
      () => BackupSnapshot.fromJson({
        ...document({'settings': {}}),
        'secret': 'fixture-secret',
      }),
      throwsA(isA<BackupValidationException>()),
    );
  });
}
