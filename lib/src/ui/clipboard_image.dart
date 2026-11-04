import 'dart:io';

import 'package:flutter/material.dart';

import '../models/clipboard_item.dart';
import 'app_theme.dart';

class ClipboardImage extends StatefulWidget {
  const ClipboardImage({
    super.key,
    required this.item,
    this.thumbnail = false,
    this.thumbnailSize,
  });
  final ClipboardItem item;
  final bool thumbnail;

  /// Maximum logical size used to decode larger list previews without distortion.
  final Size? thumbnailSize;

  @override
  State<ClipboardImage> createState() => _ClipboardImageState();
}

class _ClipboardImageState extends State<ClipboardImage> {
  ImageProvider? _provider;

  void _read() {
    try {
      final path = widget.item.imagePath;
      _provider = path == null
          ? MemoryImage(widget.item.payload.imageBytes)
          : FileImage(File(path));
    } on FormatException {
      _provider = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(covariant ClipboardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.contentHash != widget.item.contentHash ||
        oldWidget.item.imagePath != widget.item.imagePath) {
      _read();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.thumbnail
        ? const Icon(
            Icons.broken_image_outlined,
            color: AppColors.muted,
            size: 20,
          )
        : const Center(
            child: Text('图片无法预览', style: TextStyle(color: AppColors.muted)),
          );
    if (_provider == null) return fallback;
    ImageProvider provider = _provider!;
    if (widget.thumbnail) {
      final size = widget.thumbnailSize;
      final scale = MediaQuery.devicePixelRatioOf(context);
      provider = size == null
          ? ResizeImage(
              provider,
              width: 96,
              height: 96,
              policy: ResizeImagePolicy.fit,
            )
          : ResizeImage(
              provider,
              width: (size.width * scale).ceil(),
              height: (size.height * scale).ceil(),
              policy: ResizeImagePolicy.fit,
            );
    }
    final image = Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: false,
      errorBuilder: (_, error, stackTrace) => fallback,
    );
    if (widget.thumbnail) {
      return ClipRRect(borderRadius: BorderRadius.circular(6), child: image);
    }
    return InteractiveViewer(
      key: ValueKey(widget.item.contentHash),
      minScale: 0.5,
      maxScale: 5,
      child: Center(child: image),
    );
  }
}
