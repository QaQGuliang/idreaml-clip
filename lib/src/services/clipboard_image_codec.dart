import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/clipboard_content.dart';

const maxClipboardImageBytes = 32 * 1024 * 1024;
const _maxImagePixels = 40 * 1000 * 1000;

/// Read dimensions from the encoded header without decoding pixel frames.
(int, int)? clipboardImageDimensions(Uint8List bytes) {
  try {
    if (bytes.length > maxClipboardImageBytes) return null;
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (info.width, info.height);
  } catch (_) {
    return null;
  }
}

String? imageMimeType(Uint8List bytes) {
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((v) => v);
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (starts([255, 216, 255])) return 'image/jpeg';
  if (starts([71, 73, 70, 56])) return 'image/gif';
  if (starts([66, 77])) return 'image/bmp';
  if (bytes.length >= 12 &&
      starts([82, 73, 70, 70]) &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

img.Image decodeClipboardImage(
  Uint8List bytes, {
  int maxBytes = maxClipboardImageBytes,
}) {
  if (bytes.length > maxBytes) {
    throw const FormatException('图片超过 32 MB，未记录');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > _maxImagePixels) {
    throw const FormatException('图片损坏或尺寸过大，无法读取');
  }
  final image = decoder!.decodeFrame(0);
  if (image == null) throw const FormatException('无法解码图片');
  return image;
}

/// Called in a worker isolate: verify encoded data while retaining JPEG/PNG
/// originals, so the displayed type describes the bytes we actually store.
ClipboardContent encodedClipboardImage(Uint8List bytes) {
  final mime = imageMimeType(bytes);
  if (mime == null) throw const FormatException('不支持的图片格式');
  decodeClipboardImage(bytes);
  return ClipboardContent.image(bytes, mime);
}

/// Clipboard CF_DIB omits the 14-byte BMP file header. Account for palette and
/// bit masks before asking the image decoder to interpret rows and channels.
Uint8List dibToBmp(Uint8List dib) {
  if (dib.length < 40) throw const FormatException('无效的剪切板位图');
  final header = ByteData.sublistView(dib);
  final size = header.getUint32(0, Endian.little);
  if (![40, 52, 56, 108, 124].contains(size) || dib.length < size) {
    throw const FormatException('不支持的剪切板位图头');
  }
  final bits = header.getUint16(14, Endian.little);
  final compression = header.getUint32(16, Endian.little);
  final usedColors = header.getUint32(32, Endian.little);
  final palette = usedColors != 0 ? usedColors : (bits <= 8 ? 1 << bits : 0);
  final masks = size == 40
      ? (compression == 3 ? 12 : (compression == 6 ? 16 : 0))
      : 0;
  final offset = size + masks + palette * 4;
  if (offset >= dib.length) throw const FormatException('剪切板位图缺少像素数据');
  final bmp = Uint8List(dib.length + 14);
  final file = ByteData.sublistView(bmp);
  file.setUint16(0, 0x4d42, Endian.little);
  file.setUint32(2, bmp.length, Endian.little);
  file.setUint32(10, offset + 14, Endian.little);
  bmp.setRange(14, bmp.length, dib);
  return bmp;
}

ClipboardContent dibClipboardImage(Uint8List dib) {
  final image = decodeClipboardImage(
    dibToBmp(dib),
    maxBytes: 160 * 1024 * 1024,
  );
  // BI_RGB's fourth byte is reserved, not an alpha channel. Screenshots from
  // older applications often fill it with zero and would otherwise disappear.
  final header = ByteData.sublistView(dib);
  if (header.getUint32(16, Endian.little) == 0 && image.numChannels == 4) {
    for (final pixel in image) {
      pixel.a = 255;
    }
  }
  final png = img.encodePng(image);
  if (png.length > maxClipboardImageBytes) {
    throw const FormatException('图片超过 32 MB，未记录');
  }
  return ClipboardContent.image(png, 'image/png');
}

class ClipboardImageFormats {
  const ClipboardImageFormats(this.png, this.dib);
  final Uint8List png;
  final Uint8List dib;
}

ClipboardImageFormats imageForClipboard(Uint8List bytes) {
  final image = decodeClipboardImage(bytes);
  final pixels = image.getBytes(order: img.ChannelOrder.bgra);
  // A top-down BITMAPV5HEADER explicitly describes the alpha channel.
  final dib = Uint8List(124 + pixels.length);
  final data = ByteData.sublistView(dib);
  data.setUint32(0, 124, Endian.little);
  data.setInt32(4, image.width, Endian.little);
  data.setInt32(8, -image.height, Endian.little);
  data.setUint16(12, 1, Endian.little);
  data.setUint16(14, 32, Endian.little);
  data.setUint32(16, 3, Endian.little); // BI_BITFIELDS
  data.setUint32(20, pixels.length, Endian.little);
  data.setUint32(40, 0x00ff0000, Endian.little);
  data.setUint32(44, 0x0000ff00, Endian.little);
  data.setUint32(48, 0x000000ff, Endian.little);
  data.setUint32(52, 0xff000000, Endian.little);
  data.setUint32(56, 0x73524742, Endian.little); // LCS_sRGB
  data.setUint32(108, 4, Endian.little); // LCS_GM_IMAGES
  dib.setRange(124, dib.length, pixels);
  return ClipboardImageFormats(
    imageMimeType(bytes) == 'image/png' ? bytes : img.encodePng(image),
    dib,
  );
}
