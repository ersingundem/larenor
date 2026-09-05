int? proxmoxInteger(Object? value, {int min = 0}) {
  if (value is! num ||
      !value.isFinite ||
      value < min ||
      value > 9007199254740991 ||
      value != value.truncateToDouble()) {
    return null;
  }
  return value.toInt();
}

double? proxmoxFraction(Object? value) =>
    value is num && value.isFinite && value >= 0 && value <= 1
    ? value.toDouble()
    : null;
double? proxmoxRatio(int? used, int? total) =>
    used != null && total != null && used >= 0 && total > 0 && used <= total
    ? used / total
    : null;
String? proxmoxText(Object? value) =>
    value is String && value.trim().isNotEmpty && value.length <= 4096
    ? value
    : null;
String proxmoxIdentity(Object? value) {
  final result = proxmoxText(value);
  if (result == null ||
      result == '.' ||
      result == '..' ||
      result.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('Invalid resource identity.');
  }
  return result;
}

bool? proxmoxFlag(Object? value) => switch (value) {
  true || 1 => true,
  false || 0 => false,
  _ => null,
};
