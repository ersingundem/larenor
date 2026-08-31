/// A static port-forwarding / NAT rule, from `GET /rci/ip/static`. Shown
/// read-only. Field names aren't fully verified against a live router, so
/// parsing is maximally lenient — worst case a row shows fewer details,
/// never a crash.
class KeeneticPortForward {
  const KeeneticPortForward({
    required this.protocol,
    this.port,
    this.toAddress,
    this.comment,
  });

  final String protocol;
  final String? port;
  final String? toAddress;
  final String? comment;

  String get label => comment?.isNotEmpty == true
      ? comment!
      : '$protocol${port != null ? ' :$port' : ''}';

  factory KeeneticPortForward.fromJson(Map<String, dynamic> json) =>
      KeeneticPortForward(
        protocol: json['protocol'] as String? ?? 'tcp',
        port: json['port']?.toString(),
        toAddress: json['to'] as String? ?? json['address'] as String?,
        comment: json['comment'] as String? ?? json['description'] as String?,
      );
}
