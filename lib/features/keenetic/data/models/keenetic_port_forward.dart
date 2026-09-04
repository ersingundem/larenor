/// A static port-forwarding / NAT rule, from `GET /rci/ip/static`. Shown
/// read-only. RCI uses the CLI argument names (`to-address`, `to-port`,
/// `end-port`); older aliases remain accepted for compatibility.
class KeeneticPortForward {
  const KeeneticPortForward({
    required this.protocol,
    this.port,
    this.toAddress,
    this.comment,
    this.endPort,
    this.toPort,
    this.interfaceId,
  });

  final String protocol;
  final String? port;
  final String? toAddress;
  final String? comment;
  final String? endPort;
  final String? toPort;
  final String? interfaceId;

  String? get portRange => port == null
      ? null
      : endPort == null
      ? port
      : '$port–$endPort';

  String? get destination => toAddress == null
      ? null
      : toPort == null
      ? toAddress
      : '$toAddress:$toPort';

  String get label => comment?.isNotEmpty == true
      ? comment!
      : '$protocol${portRange != null ? ' :$portRange' : ''}';

  factory KeeneticPortForward.fromJson(Map<String, dynamic> json) =>
      KeeneticPortForward(
        protocol: json['protocol'] as String? ?? 'any',
        port: json['port']?.toString(),
        endPort: json['end-port']?.toString(),
        toPort: json['to-port']?.toString(),
        interfaceId: json['interface'] as String?,
        toAddress:
            json['to-address'] as String? ??
            json['to-host'] as String? ??
            json['to-interface'] as String? ??
            json['to'] as String?,
        comment: json['comment'] as String? ?? json['description'] as String?,
      );
}
