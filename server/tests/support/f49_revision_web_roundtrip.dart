import 'dart:convert';

void main() {
  // Same deterministic 52-bit digest projection asserted by the Python gate.
  const expected = 0x743eb1692de24;
  const wire = '{"revision":2045001812074020}';
  final decoded = (jsonDecode(wire) as Map<String, dynamic>)['revision'];
  if (decoded is! int || decoded != expected) {
    throw StateError('f49_revision_decode_not_exact');
  }
  final encoded = jsonEncode({'revision': decoded});
  final roundTrip = (jsonDecode(encoded) as Map<String, dynamic>)['revision'];
  if (roundTrip != expected) {
    throw StateError('f49_revision_roundtrip_not_exact');
  }
  print('f49-js-revision-exact:$roundTrip');
}
