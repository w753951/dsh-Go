import Foundation
import UIKit
import UserNotifications

/// A bounded transition delay, not a claim that screenshot pixels are stable.
/// It owns no screen observation and never grants or dispatches a phone action.
struct IOSPhoneTargetWait {
  enum Decision: Equatable { case waiting, ready, refused }
  private let deadline: TimeInterval
  private var lastSample: TimeInterval
  private var backgroundStarted: TimeInterval?
  private var keepingAliveSince: TimeInterval?

  init?(start: TimeInterval?, requestRemaining: TimeInterval) {
    guard let start, start.isFinite, requestRemaining.isFinite, requestRemaining > 0 else { return nil }
    let deadline = start + min(45, requestRemaining)
    guard deadline.isFinite, deadline > start else { return nil }
    self.deadline = deadline; lastSample = start
  }

  mutating func sample(now: TimeInterval?, background: Bool, protectedDataAvailable: Bool,
                       eligible: Bool, keepingAlive: Bool) -> Decision {
    guard let now, now.isFinite, now >= lastSample, now < deadline,
      protectedDataAvailable, eligible else { return .refused }
    lastSample = now
    guard background else {
      // Once the user has left, returning to this app cancels this admission.
      return backgroundStarted == nil ? .waiting : .refused
    }
    if backgroundStarted == nil { backgroundStarted = now }
    if let since = keepingAliveSince {
      guard keepingAlive else { return .refused }
      return now - since >= 0.75 ? .ready : .waiting
    }
    // Preserve the existing three-second opportunity for automatic PiP startup.
    guard let started = backgroundStarted, now - started < 3 else { return .refused }
    if keepingAlive { keepingAliveSince = now }
    return .waiting
  }
}

/// A thirty-minute task grant and a new native button tap for every tool call.
/// Neither a notification, a model result, nor the general approval service can
/// supply the per-call answer. Only IOSPhoneActions' current native sheet can.
@MainActor
final class IOSPhoneTaskConsent {
  private struct Owner: Equatable {
    let runID: String
    let sessionID: String
  }
  private let actions: IOSPhoneActions
  private let now: () -> TimeInterval?
  private var grantOwner: Owner?
  private var grantedAt: TimeInterval?
  private var grantedUntil: TimeInterval?
  private var lastGrantSample: TimeInterval?
  private var grantID = UUID()
  private var expiryWatcher: Task<Void, Never>?
  private var generation = UUID()
  /// 用户选择「允许并记住」后置为 true。之后不再逐次弹授权页。
  /// 关闭「手机操控」总开关会撤销它，下次需要重新确认一次。
  private var alwaysAllow: Bool {
    get { UserDefaults.standard.bool(forKey: "dsh.ios.phone.consent.always") }
    set { UserDefaults.standard.set(newValue, forKey: "dsh.ios.phone.consent.always") }
  }
  private static let alwaysAllowSeconds: TimeInterval = 365 * 24 * 3600

  /// 关闭「手机操控」总开关时调用，让下次使用重新确认一次。
  /// 不放在 retire() 里：切换对话也会 retire，那样会退化成每次都要授权。
  static func clearAlwaysAllow() {
    UserDefaults.standard.set(false, forKey: "dsh.ios.phone.consent.always")
  }
  /// Called synchronously, once, after the exact current grant has been cleared.
  /// No request/presenter closure is retained for the thirty-minute lifetime.
  var onExpiration: ((String, String) -> Void)?
  /// The runner installs an exact-invocation cleanup closure. A clipboard
  /// confirmation snapshots it before awaiting UI; a later invocation cannot
  /// donate its cleanup hook to an older answer. This never revokes a grant.
  var onClipboardRefusal: (() -> Void)?
  private(set) var targetWaitFailureMessage = "等待目标界面超时，没有派发动作。"

  init(actions: IOSPhoneActions, now: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now) {
    self.actions = actions; self.now = now
  }

  func retire() {
    expiryWatcher?.cancel(); expiryWatcher = nil; grantID = UUID()
    generation = UUID(); grantOwner = nil; grantedAt = nil; grantedUntil = nil
    lastGrantSample = nil
    onClipboardRefusal = nil
  }

  var isGranted: Bool {
    remainingSeconds > 0
  }

  var remainingSeconds: TimeInterval { checkExpiration() }

  @discardableResult
  func checkExpiration() -> TimeInterval {
    guard let owner = grantOwner, let start = grantedAt, let until = grantedUntil else { return 0 }
    if let sample = now(), let previous = lastGrantSample,
      start.isFinite, start >= 0, until.isFinite, until > start,
      previous.isFinite, previous >= start,
      sample.isFinite, sample >= previous, sample < until {
      lastGrantSample = sample
      return until - sample
    }
    // Clear identity and cancel the timer before the owner callback can reenter.
    retire()
    onExpiration?(owner.runID, owner.sessionID)
    return 0
  }

  private func watchGrant() {
    expiryWatcher?.cancel()
    let id = UUID(); grantID = id
    // This runs only while the app/actor is scheduled. The continuous clock
    // includes sleep; every admission also checks it synchronously on return.
    expiryWatcher = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        guard !Task.isCancelled, let self, self.grantID == id else { return }
        if self.checkExpiration() <= 0 { return }
      }
    }
  }

  func approve(_ request: IOSPhoneRequest, detail: String, needsTarget: Bool, preview: Data? = nil,
               current: @escaping () -> Bool) async -> Bool {
    checkExpiration()
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live(), detail.utf8.count <= 16_384,
      await waitForForeground(request, current: live) else { return false }
    let reusesGrant = grantOwner == owner && isGranted
    // isGranted can synchronously retire an expired grant and its connection.
    // Do not show a new grant sheet for the now-retired invocation.
    guard live() else { return false }
    if alwaysAllow {
      // 已经长期允许：沿用同一份授权，不再弹授权页。
      if grantOwner != owner || grantedUntil == nil {
        guard let now = self.now(), now.isFinite, now >= 0 else { return false }
        grantOwner = owner; grantedAt = now
        grantedUntil = now + Self.alwaysAllowSeconds
        lastGrantSample = now
        watchGrant()
      }
    } else if !reusesGrant {
      let granted = await actions.confirm(request, title: "允许 AI 操控这台手机？",
        detail: "允许后本机会记住这个选择，不再逐次询问——读取屏幕、打开应用、触摸和输入都不再单独确认。密码、验证码和支付信息始终交给你处理。\n\n要撤销，关闭「手机操控」总开关即可，下次使用会重新确认一次。",
        allow: "允许并记住", deny: "拒绝")
      guard granted, live(), foreground, let now = self.now(), now.isFinite, now >= 0 else { return false }
      alwaysAllow = true
      grantOwner = owner; grantedAt = now
      grantedUntil = now + Self.alwaysAllowSeconds
      lastGrantSample = now
      watchGrant()
    }
    guard live(), isGranted else { return false }
    // 长期允许下不再逐次确认；失败由具体动作自己报告。
    if alwaysAllow && grantOwner == owner {
      return live() && foreground
    }
    let suffix = needsTarget
      ? "\n\n允许后，请自行切回要操控的界面。DSH Go 会重新核对屏幕；界面变化时不继续。通知点击本身不批准。"
      : "\n\n仅执行本次调用；这不批准后续动作。"
    let clipboardSteps = (try? IOSPhoneOperation(request))?.usesClipboard == true
      ? "\n\n如果使用 CoreDevice 输入非 ASCII 文字：先切回目标检查焦点，再回到 DSH Go 确认临时剪贴板，最后切回目标粘贴。即使没有通知，也请在焦点点击后回到本 App；焦点检查未通过时不会修改剪贴板。"
      : ""
    let allowed = await actions.confirm(request, title: "允许这一次手机动作？",
      detail: detail + suffix + clipboardSteps, allow: "允许这一次", deny: "拒绝", preview: preview)
    return allowed && live() && isGranted && grantOwner == owner && foreground
  }

  func prepareForeground(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    await waitForForeground(request, current: current)
  }

  /// A focus check in the target must precede this additional staging sheet.
  /// Returning to DSH Go alone does not authorize a clipboard replacement.
  func prepareClipboard(_ request: IOSPhoneRequest, current: @escaping () -> Bool) async -> Bool {
    guard (try? IOSPhoneOperation(request))?.usesClipboard == true else { return false }
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && self.grantOwner == owner && self.isGranted
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live() else { return false }
    let refused = onClipboardRefusal
    var admitted = false
    defer { if !admitted { refused?() } }
    guard await waitForForeground(request, current: live,
      notificationBody: "已检查本次输入目标的键盘线索。请回到 DSH Go 确认临时剪贴板；尚未修改剪贴板或输入文字。"),
      live(), foreground else { return false }
    let windowSeconds = Int(IOSPhoneClipboard.pasteLifetime)
    let allowed: Bool
    if alwaysAllow {
      // 长期允许下不再单独确认剪贴板；暂存与恢复仍按原流程执行。
      allowed = live() && foreground
    } else {
      allowed = await actions.confirm(request, title: "准备本次非 ASCII 粘贴？",
        detail: "刚才已复核目标画面并检查键盘和敏感输入线索；这些线索不是输入焦点或安全性的证明。\n\n现在会在前台保存原剪贴板，并临时写入本次已批准的全文。原内容只保存在本 App 内存，不发送给模型。\n\n允许后请在 \(windowSeconds) 秒内自行切回刚才的输入界面，期间不要复制其他内容。DSH Go 会再次核对画面；后台无法回读剪贴板，不能保证发现其他 App 的并发复制。\n\n粘贴后只返回固定状态，不回传新的读屏文字或图片，也不会自动派发回车／发送按键；请你核对目标应用的实际结果。\n\n粘贴后请回到 DSH Go 核对并恢复原剪贴板；App 终止会丢失保存的原内容。取消不会撤回已派发的焦点点击。",
        allow: "准备剪贴板", deny: "取消输入")
    }
    admitted = allowed && live() && foreground
    return admitted
  }

  /// Waiting for the user to choose a target is not an automatic app switch.
  /// A protected-data lock or an actual loss of PiP stops admission immediately.
  func waitForTarget(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    let operation = generation
    targetWaitFailureMessage = "等待目标界面超时，没有派发动作。"
    guard var wait = IOSPhoneTargetWait(start: now(),
      requestRemaining: request.expiresAt / 1000 - Date().timeIntervalSince1970) else { return false }
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    var previousGate = ""
    #endif
    while true {
      // 「别的 App 在屏幕上」既可能是正常后台，也可能是真后台 tweak 把所有
      // App 都留在 active 的情况；只要真正的前台不是自己就算就位。
      let background = UIApplication.shared.applicationState == .background
      let otherAppInFront = IOSPhoneCoreDevice.otherAppInFront
      let unlocked = UIApplication.shared.isProtectedDataAvailable
      let eligible = !Task.isCancelled && current() && generation == operation && isGranted
        && request.expiresAt > Date().timeIntervalSince1970 * 1000
      let keepingAlive = (background || otherAppInFront) && unlocked
      let inBackground = background || otherAppInFront
      #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
      let gate = "target wait bg=\(background) other=\(otherAppInFront) unlocked=\(unlocked) eligible=\(eligible) pip=\(keepingAlive) usable=\(IOSPetOverlay.shared.isUsable)"
      if gate != previousGate { previousGate = gate; IOSPhoneSelfRunner.diagnostic(gate) }
      #endif
      let decision = wait.sample(now: now(), background: inBackground,
        protectedDataAvailable: unlocked, eligible: eligible, keepingAlive: keepingAlive)
      switch decision {
      case .refused:
        if !unlocked { targetWaitFailureMessage = "手机已锁定，没有派发动作；请解锁后重新发起。" }
        else if !eligible { targetWaitFailureMessage = "本次请求已取消、过期或暂停，没有派发动作；这不表示增强开关关闭。" }
        else if !inBackground { targetWaitFailureMessage = "现在屏幕上还是 DSH Go 自己。请先用 open 打开目标应用，它到前台后我再读屏。" }
        else if !keepingAlive { targetWaitFailureMessage = "目标界面已改变，未派发动作；请重新发起。" }
        #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
        IOSPhoneSelfRunner.diagnostic("target wait refused bg=\(background) eligible=\(eligible) pip=\(keepingAlive)")
        #endif
        return false
      case .ready:
        // Core/XCTest must still capture and validate a fresh frame after this
        // delay. Do not consume or replace the approved observation here.
        return true
      case .waiting:
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
      }
    }
  }

  private var foreground: Bool {
    UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
  }

  private func waitForForeground(_ request: IOSPhoneRequest, current: () -> Bool,
                                notificationBody: String = "请回到 DSH Go 查看这一次动作。点这条通知只打开 App，不会批准或执行。") async -> Bool {
    if foreground { return current() }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if current(), [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
      let content = UNMutableNotificationContent()
      content.title = "手机操控等待你确认"
      content.body = notificationBody
      // No action/category identifiers and no tool arguments or clipboard data.
      try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    defer { center.removeDeliveredNotifications(withIdentifiers: [request.id]) }
    while !Task.isCancelled, current() {
      if foreground { return true }
      do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
    }
    return false
  }
}
