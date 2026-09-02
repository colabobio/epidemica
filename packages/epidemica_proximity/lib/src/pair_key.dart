import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A key both participants in an encounter compute identically.
///
/// SHA-256 over the two pseudonyms sorted lexicographically and joined with a NUL byte.
/// Sorting is what makes it symmetric: A's recording and B's recording of the same
/// encounter carry the same key, so the server can reconcile the two halves without
/// being told, or being able to work out, which participant is which.
String pairKey(String a, String b) {
  final ordered = a.compareTo(b) <= 0 ? [a, b] : [b, a];
  final bytes = <int>[
    ...utf8.encode(ordered[0]),
    0,
    ...utf8.encode(ordered[1]),
  ];
  return sha256.convert(bytes).toString();
}
