import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import '../models/clipboard_content.dart';
import 'clipboard_image_codec.dart';
import 'clipboard_service.dart';

class WindowsClipboardService extends ClipboardService {
  int _owner = 0;
  final Map<String, int> _formats = {};
  int? _readSequence;

  @override
  int? get lastReadSequence => _readSequence;

  int _format(String name) => _formats.putIfAbsent(name, () {
    final native = name.toNativeUtf16();
    try {
      return RegisterClipboardFormat(native);
    } finally {
      calloc.free(native);
    }
  });

  @override
  int get sequence => GetClipboardSequenceNumber();

  int get _window {
    if (_owner != 0) return _owner;
    final name = 'STATIC'.toNativeUtf16();
    try {
      _owner = CreateWindowEx(
        0,
        name,
        nullptr,
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        0,
        0,
        nullptr,
      );
      if (_owner == 0) _fail('无法创建剪切板窗口');
      return _owner;
    } finally {
      calloc.free(name);
    }
  }

  Never _fail(String message) =>
      throw PlatformException(code: 'clipboard_unavailable', message: message);

  Uint8List? _readBytes(int format) {
    if (format == 0 || IsClipboardFormatAvailable(format) == 0) return null;
    final handle = GetClipboardData(format);
    if (handle == 0) _fail('剪切板暂时不可用，请重试');
    final memory = Pointer<Void>.fromAddress(handle);
    final length = GlobalSize(memory);
    // Uncompressed DIB data needs more space than an encoded PNG.
    if (length > 160 * 1024 * 1024) throw const FormatException('剪切板内容过大，未记录');
    if (length == 0) return null;
    final pointer = GlobalLock(memory);
    if (pointer == nullptr) _fail('无法读取剪切板');
    try {
      return Uint8List.fromList(pointer.cast<Uint8>().asTypedList(length));
    } finally {
      GlobalUnlock(memory);
    }
  }

  @override
  Future<List<ClipboardContent>> read() async {
    if (OpenClipboard(_window) == 0) _fail('剪切板正被其他程序使用');
    Uint8List? encoded;
    Uint8List? dib;
    String? text;
    final paths = <String>[];
    try {
      for (final name in [
        'PNG',
        'JFIF',
        'image/png',
        'image/jpeg',
        'GIF',
        'image/gif',
        'image/webp',
      ]) {
        final bytes = _readBytes(_format(name));
        if (bytes != null && imageMimeType(bytes) != null) {
          encoded = bytes;
          break;
        }
      }
      if (encoded == null) {
        // A copied image file retains its original encoding and extension.
        if (IsClipboardFormatAvailable(CF_HDROP) != 0) {
          final drop = GetClipboardData(CF_HDROP);
          if (drop == 0) _fail('无法读取复制的图片文件');
          final count = DragQueryFile(drop, 0xffffffff, nullptr, 0);
          for (var i = 0; i < count; i++) {
            final length = DragQueryFile(drop, i, nullptr, 0);
            final buffer = calloc<Uint16>(length + 1).cast<Utf16>();
            try {
              DragQueryFile(drop, i, buffer, length + 1);
              paths.add(buffer.toDartString());
            } finally {
              calloc.free(buffer);
            }
          }
        }
        dib = _readBytes(CF_DIBV5) ?? _readBytes(CF_DIB);
      }
      final unicode = _readBytes(CF_UNICODETEXT);
      if (unicode != null) {
        final units = ByteData.sublistView(unicode);
        final chars = <int>[];
        for (var i = 0; i + 1 < unicode.length; i += 2) {
          final char = units.getUint16(i, Endian.little);
          if (char == 0) break;
          chars.add(char);
        }
        text = String.fromCharCodes(chars);
      }
    } finally {
      // Delayed rendering may itself advance the sequence. Capture the value
      // while the clipboard is still locked, before asynchronous image decoding.
      _readSequence = sequence;
      CloseClipboard();
    }

    // No asynchronous decoding or disk access while the system clipboard is locked.
    if (encoded != null) return [await compute(encodedClipboardImage, encoded)];
    final images = <ClipboardContent>[];
    for (final path in paths) {
      if (!RegExp(
        r'\.(png|jpe?g|gif|bmp|webp)$',
        caseSensitive: false,
      ).hasMatch(path)) {
        continue;
      }
      final file = File(path);
      if (!await file.exists()) continue;
      if (await file.length() > maxClipboardImageBytes) {
        throw const FormatException('图片超过 32 MB，未记录');
      }
      images.add(
        await compute(encodedClipboardImage, await file.readAsBytes()),
      );
    }
    if (images.isNotEmpty) return images;
    if (dib != null) return [await compute(dibClipboardImage, dib)];
    return text == null || text.trim().isEmpty
        ? []
        : [ClipboardContent.text(text)];
  }

  Pointer _allocate(Uint8List bytes) {
    final handle = GlobalAlloc(GMEM_MOVEABLE, bytes.length);
    if (handle == nullptr) _fail('无法分配剪切板内存');
    final pointer = GlobalLock(handle);
    if (pointer == nullptr) {
      GlobalFree(handle);
      _fail('无法写入剪切板');
    }
    try {
      pointer.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    } finally {
      GlobalUnlock(handle);
    }
    return handle;
  }

  @override
  Future<void> write(ClipboardContent content) async {
    final values = <int, Uint8List>{};
    if (content.isImage) {
      final original = content.imageBytes;
      final formats = await compute(imageForClipboard, original);
      values[_format('PNG')] = formats.png;
      values[CF_DIBV5] = formats.dib;
      if (content.type == 'image/jpeg') values[_format('JFIF')] = original;
    } else {
      final bytes = Uint8List((content.content.length + 1) * 2);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < content.content.length; i++) {
        data.setUint16(i * 2, content.content.codeUnitAt(i), Endian.little);
      }
      values[CF_UNICODETEXT] = bytes;
    }
    final allocations = <int, Pointer>{};
    try {
      // Allocate before clearing, so allocation failures preserve the clipboard.
      for (final entry in values.entries) {
        allocations[entry.key] = _allocate(entry.value);
      }
      if (OpenClipboard(_window) == 0) _fail('剪切板正被其他程序使用，请重试');
      try {
        if (EmptyClipboard() == 0) _fail('无法更新剪切板');
        for (final entry in allocations.entries.toList()) {
          if (SetClipboardData(entry.key, entry.value.address) == 0) {
            _fail('无法写入剪切板');
          }
          allocations.remove(entry.key); // Windows now owns this memory.
        }
      } finally {
        CloseClipboard();
      }
    } finally {
      for (final memory in allocations.values) {
        GlobalFree(memory);
      }
    }
  }

  @override
  void dispose() {
    if (_owner != 0) {
      DestroyWindow(_owner);
      _owner = 0;
    }
  }
}
