import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/services/clipboard_image_codec.dart';

void main() {
  test('JSON 对象和数组经过解析识别，普通或不完整文本仍为 TEXT', () {
    expect(const ClipboardContent.text(' {"a": [1, true]} ').typeLabel, 'JSON');
    expect(const ClipboardContent.text('[1, "text"]').typeLabel, 'JSON');
    for (final text in ['{invalid}', '[1,]', '123', 'hello']) {
      expect(ClipboardContent.text(text).typeLabel, 'TEXT');
    }
  });

  test('PNG 和 JPG 按实际编码识别并保留原始字节', () {
    final image = img.Image(width: 2, height: 1)
      ..setPixelRgba(0, 0, 255, 0, 0, 255);
    for (final entry in {
      'PNG': img.encodePng(image),
      'JPG': img.encodeJpg(image),
    }.entries) {
      final payload = encodedClipboardImage(entry.value);
      expect(payload.typeLabel, entry.key);
      expect(payload.imageBytes, entry.value);
      expect(payload.summary, '${entry.key} 图片');
      expect(payload.hash, isNot(ClipboardContent.text(payload.content).hash));
    }
  });

  test('复制图片生成可互操作的 PNG 和 DIBV5，透明度及上下方向不变', () {
    final image = img.Image(width: 2, height: 2, numChannels: 4)
      ..setPixelRgba(0, 0, 255, 0, 0, 255)
      ..setPixelRgba(0, 1, 0, 0, 255, 128);
    final png = img.encodePng(image);
    final formats = imageForClipboard(png);
    expect(formats.png, png);
    final roundtrip = img.decodePng(dibClipboardImage(formats.dib).imageBytes)!;
    expect(roundtrip.getPixel(0, 0).r, 255);
    expect(roundtrip.getPixel(0, 1).b, 255);
    expect(roundtrip.getPixel(0, 1).a, 128);
  });

  test('普通 24 位 DIB 正确恢复行填充和上下方向', () {
    final image = img.Image(width: 3, height: 2)
      ..setPixelRgb(0, 0, 255, 0, 0)
      ..setPixelRgb(0, 1, 0, 255, 0);
    final bmp = img.encodeBmp(image);
    final payload = dibClipboardImage(Uint8List.sublistView(bmp, 14));
    final decoded = img.decodePng(payload.imageBytes)!;
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 1).g, 255);
    expect(payload.typeLabel, 'PNG');
  });

  test('BI_RGB 的保留字节为零时截图仍不透明', () {
    final dib = Uint8List(44);
    final header = ByteData.sublistView(dib);
    header.setUint32(0, 40, Endian.little);
    header.setInt32(4, 1, Endian.little);
    header.setInt32(8, 1, Endian.little);
    header.setUint16(12, 1, Endian.little);
    header.setUint16(14, 32, Endian.little);
    dib[42] = 255;
    final decoded = img.decodePng(dibClipboardImage(dib).imageBytes)!;
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 0).a, 255);
  });

  test('损坏的图片和 DIB 被拒绝', () {
    expect(
      () => encodedClipboardImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(() => dibToBmp(Uint8List(10)), throwsFormatException);
    expect(() => dibToBmp(Uint8List(40)), throwsFormatException);
  });
}
