import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 读剪贴板里的图片（截图、从相册或网页复制的图）。
///
/// Flutter 自带的 `Clipboard` 只有文本；图片在 `UIPasteboard` 里，要走
/// 原生通道。这里只读一次，不监听变化、不缓存。
class PasteboardImage {
  PasteboardImage._();

  static const MethodChannel _channel = MethodChannel('dsh/pasteboard-image');

  /// 剪贴板里现在有没有图片。失败按没有处理——调用方据此决定按钮是否可点。
  static Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 读出剪贴板里的图片，统一是 PNG。没有图片或读不出来时返回 null。
  static Future<PastedImage?> read() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('read');
      if (value == null || value['ok'] != true) return null;
      final data = value['data'];
      if (data is! Uint8List || data.isEmpty) return null;
      return PastedImage(
        data: data,
        mimeType: value['mimeType'] as String? ?? 'image/png',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 从剪贴板读出来的一张图。
class PastedImage {
  const PastedImage({required this.data, required this.mimeType});

  final Uint8List data;
  final String mimeType;
}
