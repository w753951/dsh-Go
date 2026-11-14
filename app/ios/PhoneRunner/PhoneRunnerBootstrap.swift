import Foundation
import Security

enum PhoneRunnerAppCatalog {
  /// 常见应用的名字 → bundle id。
  ///
  /// 原来这里只认包名格式和「设置」，其余全靠调用方传进来的 apps 列表。
  /// 但那个列表来自 LSApplicationWorkspace：沙盒里常常是空的，而且就算拿到了，
  /// 系统语言是英文时名字是 "WeChat" 而不是「微信」——于是「打开微信」这种
  /// 最基本的请求会一路 解析失败 → 报错，看着像通道坏了。
  ///
  /// 这张表是最后一道兜底，只放稳定的知名包名。
  static let aliases: [(name: String, id: String)] = [
    ("微信", "com.tencent.xin"), ("wechat", "com.tencent.xin"),
    ("qq", "com.tencent.mqq"), ("腾讯qq", "com.tencent.mqq"),
    ("支付宝", "com.alipay.iphoneclient"), ("alipay", "com.alipay.iphoneclient"),
    ("淘宝", "com.taobao.taobao4iphone"), ("taobao", "com.taobao.taobao4iphone"),
    ("高德地图", "com.autonavi.amap"), ("高德", "com.autonavi.amap"),
    ("bilibili", "tv.danmaku.bilianime"), ("哔哩哔哩", "tv.danmaku.bilianime"),
    ("抖音", "com.ss.iphone.ugc.Aweme"),
    ("微博", "com.sina.weibo"), ("weibo", "com.sina.weibo"),
    ("小红书", "com.xingin.discover"),
    ("知乎", "com.zhihu.ios"), ("zhihu", "com.zhihu.ios"),
    ("设置", "com.apple.Preferences"), ("系统设置", "com.apple.Preferences"),
    ("settings", "com.apple.Preferences"), ("system settings", "com.apple.Preferences"),
    ("相机", "com.apple.camera"), ("camera", "com.apple.camera"),
    ("照片", "com.apple.mobileslideshow"), ("photos", "com.apple.mobileslideshow"),
    ("备忘录", "com.apple.mobilenotes"), ("notes", "com.apple.mobilenotes"),
    ("计算器", "com.apple.calculator"), ("calculator", "com.apple.calculator"),
    ("时钟", "com.apple.mobiletimer"), ("clock", "com.apple.mobiletimer"),
    ("地图", "com.apple.Maps"), ("maps", "com.apple.Maps"),
    ("邮件", "com.apple.mobilemail"), ("mail", "com.apple.mobilemail"),
    ("日历", "com.apple.mobilecal"), ("calendar", "com.apple.mobilecal"),
    ("天气", "com.apple.weather"), ("weather", "com.apple.weather"),
    ("音乐", "com.apple.Music"), ("music", "com.apple.Music"),
    ("safari", "com.apple.mobilesafari"),
    ("app store", "com.apple.AppStore"),
  ]

  static func bundleID(for value: String, apps: [[String: String]] = []) -> String? {
    let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return nil }
    // 已经是包名格式就直接用，不做任何猜测。
    if wanted.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil {
      return wanted
    }
    // 别名表（名字精确匹配，忽略大小写）。
    if let alias = aliases.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
      return alias.id
    }
    // 真实列表：先按名字，再按包名兜一次。
    if let hit = apps.first(where: { $0["name"]?.caseInsensitiveCompare(wanted) == .orderedSame }) {
      return hit["id"]
    }
    return nil
  }
}

/// Shared by the app and the XCTest runner. Only encrypted readiness crosses DTX.
struct PhoneRunnerEndpoint: Codable, Equatable {
  let v: Int
  let port: Int
  let token: String
  let runId: String?

  init(v: Int = 1, port: Int, token: String, runId: String? = nil) {
    self.v = v
    self.port = port
    self.token = token
    self.runId = runId
  }

  func isValid(for expectedRunId: String? = nil) -> Bool {
    guard v == 1, (1...65535).contains(port), token.utf8.count == 64,
      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
    if let expectedRunId { return runId == expectedRunId }
    return true
  }
}

/// A fresh, nonpersistent key per launch keeps the RPC bearer out of logs,
/// launch arguments/environment, the App Group and test-result attachments.
final class PhoneRunnerHandshake {
  static let activityPrefix = "DSH_PHONE_READY_V1:"
  static let publicKeyEnvironment = "DSH_PHONE_PUBLIC_KEY"
  static let runIdEnvironment = "DSH_PHONE_RUN_ID"
  private static let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256

  enum Failure: Error {
    case invalidRun, keyGeneration, invalidPublicKey, invalidEndpoint
    case encryptionFailed, invalidCiphertext, decryptionFailed
  }

  private let privateKey: SecKey
  private let runId: String
  let publicKeyBase64: String

  init(runId: String) throws {
    guard UUID(uuidString: runId) != nil else { throw Failure.invalidRun }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
      kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
    ]
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
      let publicKey = SecKeyCopyPublicKey(key),
      let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
      throw Failure.keyGeneration
    }
    self.privateKey = key
    self.runId = runId
    publicKeyBase64 = bytes.base64EncodedString()
  }

  static func seal(_ endpoint: PhoneRunnerEndpoint, publicKeyBase64: String) throws -> String {
    guard let runId = endpoint.runId, UUID(uuidString: runId) != nil,
      endpoint.isValid(for: runId) else { throw Failure.invalidEndpoint }
    guard publicKeyBase64.utf8.count <= 4096,
      let bytes = Data(base64Encoded: publicKeyBase64), !bytes.isEmpty,
      let publicKey = SecKeyCreateWithData(bytes as CFData, [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: 2048,
      ] as CFDictionary, nil), SecKeyGetBlockSize(publicKey) == 256 else {
      throw Failure.invalidPublicKey
    }
    let plaintext = try JSONEncoder().encode(endpoint)
    guard let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, plaintext as CFData, nil) as Data? else {
      throw Failure.encryptionFailed
    }
    return encrypted.base64EncodedString()
  }

  func decodeReady(_ ciphertext: String) throws -> PhoneRunnerEndpoint {
    guard ciphertext.utf8.count <= 4096, let encrypted = Data(base64Encoded: ciphertext),
      encrypted.count == SecKeyGetBlockSize(privateKey) else { throw Failure.invalidCiphertext }
    guard let plaintext = SecKeyCreateDecryptedData(privateKey, Self.algorithm, encrypted as CFData, nil) as Data? else {
      throw Failure.decryptionFailed
    }
    let endpoint = try JSONDecoder().decode(PhoneRunnerEndpoint.self, from: plaintext)
    guard endpoint.isValid(for: runId) else { throw Failure.invalidEndpoint }
    return endpoint
  }
}
