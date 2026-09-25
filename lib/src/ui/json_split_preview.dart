import 'package:flutter/material.dart';

import '../models/json_document.dart';
import '../services/json_preview_formatter.dart';
import 'app_theme.dart';
import 'json_tree_view.dart';

class JsonSplitPreview extends StatefulWidget {
  const JsonSplitPreview({super.key, required this.content});

  final String content;

  @override
  State<JsonSplitPreview> createState() => _JsonSplitPreviewState();
}

class _JsonSplitPreviewState extends State<JsonSplitPreview> {
  late Future<JsonDocument> _formatted;

  @override
  void initState() {
    super.initState();
    _formatted = loadJsonPreview(widget.content);
  }

  @override
  void didUpdateWidget(covariant JsonSplitPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _formatted = loadJsonPreview(widget.content);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: _JsonPane(
          key: ValueKey(('raw', widget.content)),
          title: '原始文本',
          textKey: const ValueKey('json-raw-text'),
          content: widget.content,
        ),
      ),
      const VerticalDivider(width: 1, thickness: 1, color: AppColors.line),
      Expanded(
        child: FutureBuilder<JsonDocument>(
          key: ValueKey(widget.content),
          future: _formatted,
          builder: (context, snapshot) => _JsonPane(
            title: '格式化 JSON',
            textKey: const ValueKey('json-formatted-text'),
            body: snapshot.hasData
                ? JsonTreeView(
                    key: const ValueKey('json-formatted-tree'),
                    document: snapshot.data!,
                  )
                : null,
            error: snapshot.hasError ? '无法解析这段 JSON' : null,
            formatted: true,
          ),
        ),
      ),
    ],
  );
}

class _JsonPane extends StatefulWidget {
  const _JsonPane({
    super.key,
    required this.title,
    required this.textKey,
    this.content,
    this.error,
    this.formatted = false,
    this.body,
  });

  final String title;
  final Key textKey;
  final String? content;
  final String? error;
  final bool formatted;
  final Widget? body;

  @override
  State<_JsonPane> createState() => _JsonPaneState();
}

class _JsonPaneState extends State<_JsonPane> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: widget.formatted ? AppColors.primarySoft : AppColors.sidebar,
          border: const Border(bottom: BorderSide(color: AppColors.line)),
        ),
        child: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: widget.formatted ? AppColors.primary : AppColors.muted,
          ),
        ),
      ),
      Expanded(
        child:
            widget.body ??
            (widget.error != null
                ? Center(child: Text(widget.error!))
                : widget.content == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      primary: false,
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        widget.content!,
                        key: widget.textKey,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontFamilyFallback: [
                            'Microsoft YaHei UI',
                            'PingFang SC',
                            'Noto Sans CJK SC',
                            'Menlo',
                            'monospace',
                          ],
                          fontSize: 12,
                          height: 1.6,
                          color: AppColors.text,
                        ),
                      ),
                    ),
                  )),
      ),
    ],
  );
}
