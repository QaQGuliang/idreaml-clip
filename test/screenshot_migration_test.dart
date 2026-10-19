import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('旧数据库升级增加截图回执并保留历史和设置', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'idreaml-migration-',
    );
    final path = '${directory.path}/history.db';
    var database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    try {
      await database.open(path: path);
      final repository = ClipboardRepository(database);
      await repository.initializeDevice();
      await repository.captureText('已有历史');
      await repository.setSetting('recording_enabled', 'false');
      await database.database.execute('DROP TABLE screenshot_commit');
      await database.database.setVersion(1);
      await database.close();
      database = ClipboardDatabase.withFactory(databaseFactoryFfi);
      await database.open(path: path);
      final upgraded = ClipboardRepository(database);
      await upgraded.initializeDevice();
      expect((await upgraded.list()).single.content, '已有历史');
      expect(await upgraded.getSetting('recording_enabled'), 'false');
      await upgraded.captureScreenshot(
        'migration',
        const ClipboardContent.text('回执验证'),
      );
      await upgraded.captureScreenshot(
        'migration',
        const ClipboardContent.text('回执验证'),
      );
      expect((await upgraded.list()).first.copyCount, 1);
      expect(await database.database.getVersion(), 2);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
