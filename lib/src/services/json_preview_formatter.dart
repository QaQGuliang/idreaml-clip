import 'package:flutter/foundation.dart';

import '../models/json_document.dart';

String _format(String content) => parseJsonDocument(content).formatted;

Future<JsonDocument> loadJsonPreview(String content) {
  if (content.length > 16384) return compute(parseJsonDocument, content);
  try {
    return SynchronousFuture(parseJsonDocument(content));
  } catch (error, stack) {
    return Future.error(error, stack);
  }
}

Future<String> formatJsonPreview(String content) {
  // Large clipboard entries should not block scrolling or selection.
  if (content.length > 16384) return compute(_format, content);
  try {
    return SynchronousFuture(_format(content));
  } catch (error, stack) {
    return Future.error(error, stack);
  }
}
