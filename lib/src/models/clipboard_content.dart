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

  String get summary =>
      isImage ? '$typeLabel 图片' : content.replaceAll(RegExp(r'[\r\n]+'), ' ');
}
