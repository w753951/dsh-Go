import Flutter
import UIKit
import UniformTypeIdentifiers

/// 读一次剪贴板里的图片，给聊天输入框的「粘贴图片」用。
///
/// Flutter 自带的 `Clipboard` 只有文本。iOS 的截图（以及从照片、Safari
/// 复制的图）都在 `UIPasteboard.general` 里，需要通过原生读出来。
///
/// 这里只做两件事：报告剪贴板里有没有图片、把图片读成 PNG 字节。不做
/// 后台轮询、不缓存、不给别的进程留副本。每次调用读一次就结束。
final class PasteboardImageChannel {
  private let methods: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/pasteboard-image", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "available":
        result(self.hasImage())
      case "read":
        self.read(result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func hasImage() -> Bool {
    UIPasteboard.general.hasImages
  }

  /// 读剪贴板里最大的一张图，压成 PNG 返回。
  ///
  /// 用 PNG 而不是原始数据：粘贴板上可能是 HEIC、TIFF 或 P3 色彩空间的
  /// 截图，统一成 PNG 省得下游再判断格式。上限按像素和字节双重卡住，
  /// 免得一张 4800 万像素全景图把内存吃光。
  private func read(_ result: @escaping FlutterResult) {
    let pasteboard = UIPasteboard.general
    guard pasteboard.hasImages else {
      result(["ok": false, "reason": "empty"])
      return
    }
    guard let image = pasteboard.image ?? firstImage(in: pasteboard) else {
      result(["ok": false, "reason": "unreadable"])
      return
    }
    let width = image.size.width * image.scale
    let height = image.size.height * image.scale
    guard width >= 1, height >= 1 else {
      result(["ok": false, "reason": "empty"])
      return
    }
    // 太长的边先等比缩到 4096，手机截图很少超过这个数。
    let longest = max(width, height)
    let limited: UIImage
    if longest > 4096 {
      let ratio = 4096 / longest
      let target = CGSize(width: (width * ratio).rounded(), height: (height * ratio).rounded())
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      format.opaque = false
      limited = UIGraphicsImageRenderer(size: target, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
      }
    } else {
      limited = image
    }
    guard let data = limited.pngData() else {
      result(["ok": false, "reason": "encode"])
      return
    }
    // 24 MB：够一张 4096 边长的 PNG，再多就说明不是正常截图。
    guard data.count <= 24 * 1024 * 1024 else {
      result(["ok": false, "reason": "too-large"])
      return
    }
    result([
      "ok": true,
      "data": FlutterStandardTypedData(bytes: data),
      "mimeType": "image/png",
      "width": Int(limited.size.width * limited.scale),
      "height": Int(limited.size.height * limited.scale),
    ])
  }

  /// `pasteboard.image` 只认第一项；多选复制时自己找第一张能解码的。
  private func firstImage(in pasteboard: UIPasteboard) -> UIImage? {
    for item in pasteboard.items {
      for (type, value) in item {
        guard let utType = UTType(type), utType.conforms(to: .image) else { continue }
        if let data = value as? Data, let image = UIImage(data: data) { return image }
        if let image = value as? UIImage { return image }
      }
    }
    return nil
  }
}
