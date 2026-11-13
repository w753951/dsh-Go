import Foundation
import UIKit
import UserNotifications

/// Selects the user-enabled route and admits one genuinely confirmed tool call.
/// The default is the shared CoreDevice owner. XCTest is a separate opt-in;
/// uncertainty after any dispatch never authorizes switching routes or replay.
@MainActor
final class IOSPhoneRunner {
  private static let group = "group.io.github.ccch1mneyyy.dshgo"
  private static let missing =
    "手机操控没有运行，所以这一步没有执行。请告诉用户：先在 Mac 上运行 tooling/ios/phone-runner.sh，让手机操控的测试进程跑起来，再重试。不要自动反复重试。"
  static let coreStopUnconfirmed =
    "ERR_PHONE_STOP_UNCONFIRMED：开发者连接的清理尚未确认，不能继续操控或切换到 XCTest。请告诉用户：彻底关闭 DSH Go 后重新打开，再由用户发起；不要自动重试。"

  private typealias Endpoint = PhoneRunnerEndpoint

  private let actions: IOSPhoneActions
  private let session: URLSession
  private let selfRunner: IOSPhoneSelfRunner
  private let consent: IOSPhoneTaskConsent
  private let core = IOSPhoneCoreDevice.shared
  private let coreActions = IOSPhoneCoreActions()
  private enum Route { case coredevice, xctest }
  private struct Owner: Equatable {
    let runID: String
    let sessionID: String
  }
  private var taskOwner: Owner?
  private var lastRoute: Route?
  private var lastXCTestScreen: String?
  private var selfOwnerID = UUID().uuidString
  private var invocationID = UUID()
  private var lastEndpoint: Endpoint?
  private var targetApplication: String?

  init(actions: IOSPhoneActions, selfRunner: IOSPhoneSelfRunner? = nil) {
    self.actions = actions
    self.consent = IOSPhoneTaskConsent(actions: actions)
    self.selfRunner = selfRunner ?? .shared
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.connectionProxyDictionary = [:]
    session = URLSession(configuration: configuration)
    consent.onExpiration = { [weak self] runID, sessionID in
      guard let self, self.taskOwner == Owner(runID: runID, sessionID: sessionID) else { return }
      self.retireConnection(ownerID: self.selfOwnerID)
    }
  }

  /// The run is over, and what the user granted was for it.
  func retire() {
    finish()
  }

  func finish() {
    consent.retire()
    taskOwner = nil
    retireConnection(ownerID: selfOwnerID)
  }

  /// A declined call closes only this connection and its observations. It does
  /// not revoke or renew a still-valid task grant. A late refusal has no power
  /// over a newer invocation, even within the same engine/session tuple.
  private func retireConnection(ownerID: String, invocationID: UUID? = nil) {
    guard selfOwnerID == ownerID else { return }
    if let invocationID, self.invocationID != invocationID { return }
    selfOwnerID = UUID().uuidString; self.invocationID = UUID()
    coreActions.invalidate(); lastRoute = nil; lastXCTestScreen = nil
    lastEndpoint = nil
    targetApplication = nil
    consent.onClipboardRefusal = nil
    // Rotate local identities before either backend's synchronous status
    // callback can reenter. Never use an unowned stop for settings preflight.
    selfRunner.stop(ownerID: ownerID)
    core.stop(ownerID: ownerID)
  }

  /// Only the already-authorized runner may return to this app; never launch a
  /// new runner, repeat an unknown action, or choose another destination here.
  func returnToApp(current: () -> Bool) async -> Bool {
    guard current(), let endpoint = lastEndpoint,
      endpoint.runId == nil || selfRunner.owns(endpoint),
      let bundle = Bundle.main.bundleIdentifier,
      let url = URL(string: "http://127.0.0.1:\(endpoint.port)/rpc") else { return false }
    var values: [String: Any] = ["method": "open", "params": ["app": bundle],
      "expiresAt": Date().addingTimeInterval(8).timeIntervalSince1970 * 1000]
    if let runId = endpoint.runId { values["runId"] = runId }
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.timeoutInterval = 8
    http.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = try? JSONSerialization.data(withJSONObject: values)
    guard let (data, response) = try? await session.data(for: http), current(),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      result["ok"] as? Bool == true else { return false }
    return true
  }

  func cancelPreparation() {
    selfRunner.cancelPreparation(ownerID: selfOwnerID)
    IOSPhoneCoreDevice.shared.stop(ownerID: selfOwnerID)
  }

  func run(_ request: IOSPhoneRequest, authorize: @escaping () async -> Bool,
           progress: @escaping (IOSPhoneControl.Phase) -> Void = { _ in },
           current: @escaping () -> Bool) async -> IOSPhoneOutcome {
    guard current(), !Task.isCancelled else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    // Consume an old expiry before capturing this call's identities, so a fresh
    // explicit request can ask for a new grant after the old connection closes.
    consent.checkExpiration()
    guard current(), !Task.isCancelled else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    let incomingOwner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    if taskOwner != incomingOwner {
      // A different conversation cannot inherit either backend's observations,
      // the previous grant, or its native owner, even when the helper endpoint
      // remains available. This does not cancel the newly claimed bridge call.
      finish()
      taskOwner = incomingOwner
    }
    let invocationID = UUID(); self.invocationID = invocationID
    consent.onClipboardRefusal = nil
    if request.action.kind == "runner-handoff" {
      let result = await handOver(request)
      guard !result.isError, current(), !Task.isCancelled, await authorize(), current() else {
        return .failure("接手调用已结束或未确认，没有执行自动动作。")
      }
      return result
    }
    let link = IOSPhoneLink.shared
    let settingsGeneration = link.generation
    let ownerID = selfOwnerID
    consent.onClipboardRefusal = { [weak self] in
      self?.retireConnection(ownerID: ownerID, invocationID: invocationID)
    }
    let live = { !Task.isCancelled && current() && self.selfOwnerID == ownerID && self.invocationID == invocationID
      && link.generation == settingsGeneration && IOSPhoneControl.shared.enabled
      && !IOSPhoneControl.shared.isPaused
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live() else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    guard !link.isPreparing else {
      return .failure("连接设置正在处理另一项准备，请等待完成后重新发起；不是增强开关未开启。")
    }
    // 越狱通道自带抓屏和 HID 注入，既不需要「手机连接」（CoreDevice 配对），
    // 也不需要「XCTest 增强」。这两个开关在越狱设备上不再是门槛。
    let jailbreak = IOSJailbreakDevice.available()
    guard jailbreak || link.enabled || link.xctestEnabled else {
      return .failure("手机连接和 XCTest 增强均未启用。请由用户在设置中选择；已保存配对不等于授权操控。")
    }
    // 画中画已移除：越狱机的真后台插件保证进程活着，这里只确认设备解锁。
    guard IOSPhoneCoreDevice.backgroundKeepAliveAvailable else {
      return .failure("手机已锁定，没有读取或派发动作；请解锁后重新发起。")
    }
    let plan: IOSPhoneOperation
    do { plan = try IOSPhoneOperation(request) }
    catch { return .failure((error as? IOSPhoneOperationError)?.message ?? "手机动作参数无效。") }
    if plan.method == .open { targetApplication = nil }
    if plan.requiresObservation, lastRoute == nil {
      return .failure("没有本次任务的有效屏幕观察。先用 screen，不要猜编号或重放旧动作。")
    }
    let explicitApp = (plan.parameters["app"] as? String).flatMap { PhoneRunnerAppCatalog.bundleID(for: $0) }
    let preference = explicitApp.flatMap { link.appRoutes[$0] }
    // 越狱通道固定走 core 那一层（它已经被换成了越狱实现），既不配对也不走
    // XCTest，所以「某个应用固定用哪个后端」这类规则在越狱设备上不适用。
    let mustCore = !jailbreak && preference == "coredevice"
    let mustXCTest = !jailbreak && preference == "xctest"
    let chooseXCTest = !jailbreak
      && (mustXCTest || ((plan.requiresObservation || plan.method == .screen) && lastRoute == .xctest))
    guard !chooseXCTest || link.xctestEnabled else { return .failure("XCTest 增强已关闭，没有启动或调用运行器。") }
    guard !mustCore || link.enabled else { return .failure("这个应用固定使用 CoreDevice，但本机连接已关闭。") }
    let returnTarget = plan.needsTarget && link.xctestEnabled && !jailbreak ? targetApplication : nil
    let returnDescription = returnTarget.map {
      "\n\n若本次使用 XCTest，允许后会先返回本次任务已打开或观察的应用：\($0)，再重新核对屏幕。若保持 CoreDevice 路线，请自行切回目标界面。不会重复原来的点按或输入。"
    } ?? ""
    let description = plan.consentDescription(targetLabel: coreActions.targetLabel(plan, ownerID: ownerID,
      sessionID: request.owner.sessionId))
      + "\n\n路线由你的设置和可用性决定；XCTest 只在已启用时使用。已经派发或结果不明时不切换重试。"
      + returnDescription
    guard await consent.prepareForeground(request, current: live), live(),
      await IOSPhoneClipboard.shared.resolvePending(request, actions: actions, current: live), live() else {
      retireConnection(ownerID: ownerID, invocationID: invocationID)
      return .failure("请先回到 DSH Go 处理上次剪贴板恢复；没有执行新动作。")
    }
    let preview = coreActions.approvalPreview(plan, ownerID: ownerID, sessionID: request.owner.sessionId)
    guard await consent.approve(request, detail: description,
      needsTarget: returnTarget == nil && (plan.needsTarget || plan.method == .open), preview: preview, current: live),
      live(), await authorize(), live(), consent.isGranted else {
      retireConnection(ownerID: ownerID, invocationID: invocationID)
      return .failure("本次调用没有取得仍有效的逐次批准，没有派发手机动作。不要自动重试。")
    }
    progress(.connecting)

    if !chooseXCTest, jailbreak || link.enabled {
      // A new backend cannot race an owner whose teardown is still unknown.
      selfRunner.stop(ownerID: ownerID)
      let stopDeadline = Date().addingTimeInterval(12)
      while !selfRunner.mayUseMacFallback, live(), Date() < stopDeadline {
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      }
      guard live(), selfRunner.mayUseMacFallback else { return .failure(IOSPhoneSelfRunnerError.faulted.message) }
      let prepared = await core.prepare(ownerID: ownerID, current: live)
      guard live(), consent.isGranted else { core.stop(ownerID: ownerID); return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      switch prepared {
      case .success(let capabilities):
        // A fresh screen has not captured or dispatched anything yet. When
        // the native probe reports no input, an already enabled enhancement
        // can prepare a NEW XCTest observation, with normal approval below.
        // Never carry a CoreDevice element ID into an XCTest input request.
        let mayEnhance = !jailbreak && link.xctestEnabled && !mustCore && !link.appRoutes.values.contains("coredevice")
        if capabilities["touch"] == false, mayEnhance, plan.method == .screen { break }
        if capabilities["touch"] == false, link.xctestEnabled, plan.requiresObservation {
          return .failure(mayEnhance
            ? "XCTest 增强已开启。当前编号来自 CoreDevice 的只读观察；请先调用 screen 获取新的 XCTest 屏幕和编号，再操作。本次没有点击、滚动或输入，不需要重复开启开关。"
            : "XCTest 增强已开启，但当前应用规则不允许自动切换。这次没有派发输入；请用户核对应用后端规则，或 handoff。")
        }
        if lastRoute != .coredevice { coreActions.invalidate(); lastXCTestScreen = nil }
        lastRoute = .coredevice; lastEndpoint = nil
        progress(.executing)
        let outcome = await coreActions.run(plan, request: request, ownerID: ownerID, consent: consent, current: live)
        if !outcome.isError, plan.method == .open { targetApplication = coreActions.lastOpenedApplication }
        return outcome
      case .failure(let failure):
        if failure.code == "ERR_PHONE_STOP_UNCONFIRMED" || core.isFaulted {
          return .failure(Self.coreStopUnconfirmed)
        }
        // Preparing transport is the ONLY automatic fallback point. A screen
        // sharing start or any input is never retried on another backend.
        guard !jailbreak, !mustCore, !failure.mayHaveActed, core.maySwitchBackend,
          link.xctestEnabled, !link.appRoutes.values.contains("coredevice"),
          !plan.requiresObservation else {
          return .failure(failure.code + "：本次未完成连接；不自动重复动作。需要镜像时请到连接设置明确准备。")
        }
      }
    }
    // XCTest 增强已彻底移除：这台设备只用越狱通道（core 那一层早被换成了
    // 越狱实现）。走到这里说明越狱通道自己没完成这次调用，直接报失败，
    // 不再落到任何其它后端，也不再存在「增强开关」这种东西。
    return .failure("越狱通道没有完成这次调用；解锁手机后重新发起，" +
      "或先 open 打开目标应用再读屏。")
  }

  /// The user does something themselves, likely in another app, and comes back to say they did.
  /// A notification is how they find out when DSH Go isn't in front. Tapping it only opens the app.
  private func handOver(_ request: IOSPhoneRequest) async -> IOSPhoneOutcome {
    let reason = request.action.text ?? ""
    if UIApplication.shared.applicationState != .active {
      let content = UNMutableNotificationContent()
      content.title = "AI 请你接手"
      content.body = reason
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    while !Task.isCancelled, request.expiresAt > Date().timeIntervalSince1970 * 1000 {
      if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable {
        let finished = await actions.confirm(
          request, title: "AI 请你接手", detail: "\(reason)\n\n可以先切到别的应用去做，做完回来点「继续」。",
          allow: "继续", deny: "停止", waitsForever: true)
        if finished { return .success("用户说做完了。先用 screen 看一下现在的屏幕。") }
        // Leaving the app dismisses the sheet, which isn't an answer. Asked again on the way back.
        if UIApplication.shared.applicationState == .active { return .failure("用户选择停止。不要自动重试。") }
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return .failure("用户没有在时间内回来。")
  }
}
