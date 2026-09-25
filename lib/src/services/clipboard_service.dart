import 'package:flutter/services.dart';

import '../models/clipboard_content.dart';

abstract class ClipboardService {
  int? get sequence;
  int? get lastReadSequence => null;
  Future<List<ClipboardContent>> read();
  Future<void> write(ClipboardContent content);
  void dispose() {}
}

class TextClipboardService extends ClipboardService {
  @override
  int? get sequence => null;

  @override
  Future<List<ClipboardContent>> read() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    return text == null || text.trim().isEmpty
        ? []
        : [ClipboardContent.text(text)];
  }

  @override
  Future<void> write(ClipboardContent content) async {
    if (content.isImage) {
      throw PlatformException(
        code: 'image_unavailable',
        message: '当前平台暂不支持复制图片',
      );
    }
    await Clipboard.setData(ClipboardData(text: content.content));
  }
}
