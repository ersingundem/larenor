class ProxmoxConfig {
  const ProxmoxConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.realm,
    required this.password,
    required this.allowSelfSigned,
  });

  final String host;
  final int port;
  final String username;
  final String realm;
  final String password;
  final bool allowSelfSigned;

  String get baseUrl => 'https://$host:$port';

  String get userWithRealm => '$username@$realm';
}
