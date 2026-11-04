import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'json_document.dart';

/// Image bytes are stored with their MIME type, keeping the existing database
/// and sync record format compatible with text records.
class ClipboardContent {
  const ClipboardContent({required this.type, required this.content});

  const ClipboardContent.text(this.content) : type = 'text';

  factory ClipboardContent.image(Uint8List bytes, String mimeType) =>
      ClipboardContent(type: mimeType, content: base64Encode(bytes));

  final String type;
  final String content;

  bool get isImage => type.startsWith('image/');
  Uint8List get imageBytes => base64Decode(content);

  // Keep existing text hashes stable so older records still deduplicate.
  String get hash => sha256
      .convert(utf8.encode(isImage ? '$type\u0000$content' : content))
      .toString();

  String get typeLabel {
    if (isImage) {
      final format = type.substring(6).toUpperCase();
      return format == 'JPEG' ? 'JPG' : format;
    }
    return tryParseJsonDocument(content) == null ? 'TEXT' : 'JSON';
  }

  static final _lineBreaks = RegExp(r'[\r\n]+');

  String get summary {
    if (isImage) return '$typeLabel 图片';
    const limit = 256;
    if (content.length <= limit) return content.replaceAll(_lineBreaks, ' ');
    // Rows display one line. Avoid shaping or normalizing the entire entry,
    // and keep the last visible Unicode character intact.
    final last = content.codeUnitAt(limit - 1);
    final end = last >= 0xd800 && last <= 0xdbff ? limit - 1 : limit;
    return '${content.substring(0, end).replaceAll(_lineBreaks, ' ')}…';
  }
}
