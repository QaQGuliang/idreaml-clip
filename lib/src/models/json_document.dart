import 'dart:convert';

class JsonDocument {
  JsonDocument(this.value, {this.decodedLayers = 0});

  /// The outer object/array. String values inside it retain their JSON type.
  final Object value;
  final int decodedLayers;
  late final String formatted = const JsonEncoder.withIndent('  ')
      .convert(value);
}

JsonDocument? tryParseJsonDocument(String source) {
  var candidate = source.trim();
  if (candidate.startsWith('\uFEFF')) candidate = candidate.substring(1).trim();
  var layers = 0;
  // Clipboard text is sometimes a serialized JSON string, possibly copied
  // without its outer quotes. Decode whole layers, never replace backslashes.
  for (var attempt = 0; attempt < 9; attempt++) {
    if (!candidate.startsWith('{') &&
        !candidate.startsWith('[') &&
        !candidate.startsWith('"') &&
        !candidate.startsWith(r'\"')) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } on FormatException {
      if (!candidate.contains(r'\"')) return null;
      try {
        decoded = jsonDecode('"$candidate"');
      } on FormatException {
        return null;
      }
    }
    if (decoded is Map<String, dynamic> || decoded is List<dynamic>) {
      return JsonDocument(decoded!, decodedLayers: layers);
    }
    if (decoded is! String || decoded == candidate) return null;
    candidate = decoded.trim();
    layers++;
  }
  return null;
}

JsonDocument parseJsonDocument(String source) =>
    tryParseJsonDocument(source) ??
    (throw const FormatException('无法解析 JSON 对象或数组'));
