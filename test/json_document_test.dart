import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/json_document.dart';
import 'package:idreaml_clip/src/models/json_tree.dart';
import 'package:idreaml_clip/src/services/json_preview_formatter.dart';

import 'support/json_samples.dart';

void main() {
  test('用户提供的整体转义 JSON 可识别、解析和格式化，原文不变', () async {
    const payload = ClipboardContent.text(escapedJsonSample);
    expect(payload.typeLabel, 'JSON');
    final doc = parseJsonDocument(payload.content);
    expect(doc.decodedLayers, 1);
    final value = doc.value as Map;
    expect(value['name'], '张三');
    expect(value['address'], {'city': '杭州', 'district': '西湖区'});
    expect(value['tags'], ['Java', 'Spring Boot', 'MySQL']);
    expect(jsonDecode(await formatJsonPreview(payload.content)), value);
    expect(payload.content, escapedJsonSample);
  });

  test('标准转义、Unicode、反斜杠路径及 JSON 字符串字段保持含义', () {
    const source =
        r'{"quote":"他说\"你好\"","path":"C:\\new\\test.txt","line":"a\nb","unicode":"\u4F60\u597D","nested":"{\"x\":1}"}';
    final expected = jsonDecode(source);
    for (var layers = 0; layers <= 5; layers++) {
      var input = source;
      for (var i = 0; i < layers; i++) {
        input = jsonEncode(input);
      }
      final doc = parseJsonDocument(input);
      expect(doc.decodedLayers, layers);
      expect(doc.value, expected);
      expect((doc.value as Map)['nested'], isA<String>());
      expect(jsonDecode(doc.formatted), expected);
      final wrapped = jsonEncode(input);
      final unquoted = wrapped.substring(1, wrapped.length - 1);
      expect(parseJsonDocument(unquoted).value, expected);
    }
    expect(parseJsonDocument('\uFEFF$source').value, expected);
  });

  test('顶层数组、多次编码、空容器及无效文本判断一致', () {
    for (final raw in ['[]', '{}', '[{"a":true},null,3]']) {
      expect(
        ClipboardContent.text(jsonEncode(jsonEncode(raw))).typeLabel,
        'JSON',
      );
    }
    for (final text in [
      'hello',
      '123',
      '"hello"',
      r'{\"x\":}',
      r'{\"x\":\"bad\q\"}',
      '{"x":1,}',
      '[1,]',
      '"{invalid}"',
    ]) {
      expect(tryParseJsonDocument(text), isNull);
      expect(ClipboardContent.text(text).typeLabel, 'TEXT');
    }
  });

  test('大 JSON 的后台解析与格式化使用同一解码规则', () async {
    final value = {
      'data': List.generate(1500, (i) => {'id': i, 'value': 'value-$i'}),
    };
    final raw = jsonEncode(jsonEncode(value));
    expect(raw.length, greaterThan(16384));
    expect((await loadJsonPreview(raw)).value, value);
    expect(jsonDecode(await formatJsonPreview(raw)), value);
  });

  test('括号配对、数组元素与独立折叠保留兄弟节点', () {
    final doc = parseJsonDocument('{"a":{"x":[1,2]},"b":[{},[]],"c":true}');
    final lines = jsonTreeLines(doc);
    final all = lines
        .map(
          (line) =>
              '${line.prefix}${line.text}${line.comma && !line.canFold ? ',' : ''}',
        )
        .join('\n');
    expect(jsonDecode(all), doc.value);
    for (final line in lines.where((line) => line.canFold)) {
      expect(lines[line.end!].depth, line.depth);
      expect(
        lines[line.end!].text,
        line.token == JsonTreeToken.object ? '}' : ']',
      );
    }
    final a = lines.singleWhere((line) => line.name == 'a');
    final b = lines.singleWhere((line) => line.name == 'b');
    final visible = visibleJsonLines(lines, {a.index});
    expect(visible.any((line) => line.name == 'x'), isFalse);
    expect(visible.contains(b), isTrue);
    expect(visible.any((line) => line.name == 'c'), isTrue);
    expect(visibleJsonLines(lines, {0}), [lines.first]);
  });
}
