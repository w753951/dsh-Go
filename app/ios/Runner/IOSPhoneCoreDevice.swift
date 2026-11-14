import Foundation
import Darwin
import UIKit

struct IOSPhoneCoreFailure: Error {
  let code: String
  var variant: String?
  var mayHaveActed = false
}

struct IOSPhoneCoreEvent: Decodable, Sendable {
  var stage: String?
  var code: String?
  var variant: String?
  var completedBytes: Int64?
  var totalBytes: Int64?
  var capabilities: [String: Bool]?
  var cleanupConfirmed: Bool?
  var vpnReachable: Bool?
  var pairingVerified: Bool?
  var lockdownReady: Bool?
  var ddiMounted: Bool?
  var mayHaveActed: Bool?
}

struct IOSPhoneCoreReply: Sendable {
  struct Metadata: Decodable, Sendable {
    var outcome: String?
    var code: String?
    var mayHaveActed: Bool?
    var cleanupConfirmed: Bool?
    var contentType: String?
    var kind: String?
    var width: Int?
    var height: Int?
    var interfaceOrientation: Int?
    var nativeFrameId: String?
    var pid: UInt32?
    var foregroundVerified: Bool?
  }
  let status: Int32
  let metadata: Metadata
  let bytes: Data?
}

private func phoneCoreString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
  guard let pointer else { return nil }
  let count = strnlen(pointer, limit + 1)
  guard count <= limit else { return nil }
  return String(bytes: UnsafeRawBufferPointer(start: pointer, count: count), encoding: .utf8)
}

#if DSH_PHONE_SELF_RUNNER
private func phoneCoreEventCallback(_ handle: UInt64, _ run: UnsafePointer<CChar>?,
                                    _ kind: Int32, _ payload: UnsafePointer<CChar>?) {
  guard let runID = phoneCoreString(run, limit: 36), UUID(uuidString: runID) != nil else { return }
  let text = phoneCoreString(payload, limit: 8192) ?? ""
  Task { @MainActor in IOSPhoneCoreDevice.deliverEvent(handle: handle, runID: runID, kind: kind, text: text) }
}

private func phoneCoreResultCallback(_ handle: UInt64, _ requestID: UInt64, _ status: Int32,
                                     _ payload: UnsafePointer<CChar>?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
  let text = phoneCoreString(payload, limit: 8192) ?? ""
  let validBytes = count >= 0 && count <= 16 * 1024 * 1024 && (count == 0 || bytes != nil)
    && (status == 0 || count == 0)
  // The ABI's pointers expire at callback return. Copy on this thread before
  // hopping to MainActor, including screenshots and the bounded apps response.
  let data = validBytes && count > 0 ? Data(bytes: bytes!, count: count) : nil
  Task { @MainActor in
    IOSPhoneCoreDevice.deliverResult(handle: handle, requestID: requestID,
      status: validBytes ? status : -1, text: text, bytes: data)
  }
}
#endif

/// Swift owner of the CoreDevice branch of the EXISTING Rust singleton. It does
/// not create another pairing/tunnel stack or replay uncertain input on XCTest.
@MainActor
final class IOSPhoneCoreDevice: NSObject {
  typealias EventSink = @MainActor (UInt64, String, Int32, String) -> Void
  typealias ResultSink = @MainActor (UInt64, UInt64, Int32, String, Data?) -> Void
  struct NativeClient {
    // Metadata and pairing plist are separate, synchronously borrowed inputs.
    let start: @MainActor (String, Data, Data, @escaping EventSink) -> (Int32, UInt64)
    let request: @MainActor (UInt64, UInt64, Data, @escaping ResultSink) -> Int32
    let cancel: @MainActor (UInt64, UInt64) -> Void
    let stop: @MainActor (UInt64) -> Void
  }

  static let shared = IOSPhoneCoreDevice()
  private static var eventCallbacks: [String: EventSink] = [:]
  private static var resultCallbacks: [String: ResultSink] = [:]

  private final class Request {
    let id: UInt64
    let mutating: Bool
    var reply: Result<IOSPhoneCoreReply, IOSPhoneCoreFailure>?
    init(id: UInt64, mutating: Bool) { self.id = id; self.mutating = mutating }
  }

  private enum FaultOrigin: Equatable { case stopTimeout, native, protocolMismatch }

  private final class Run {
    let id = UUID().uuidString.lowercased()
    let ownerID: String
    let pairingGeneration: UUID
    let deadline: Date
    var handle: UInt64 = 0
    var capabilities: [String: Bool]?
    var checks: [String: Bool] = [:]
    var failure: IOSPhoneCoreFailure?
    var stopping = false
    var terminal = false
    var fault: FaultOrigin?
    var faulted: Bool { fault != nil }
    var pending: Request?
    var nextRequest: UInt64 = 1
    var stopElapsed: TimeInterval = 0
    var stopAnchor: TimeInterval?
    var stopLastSample: TimeInterval?
    var stopWatcher: Task<Void, Never>?
    init(ownerID: String, pairingGeneration: UUID, deadline: Date) {
      self.ownerID = ownerID; self.pairingGeneration = pairingGeneration; self.deadline = deadline
    }
  }

  private let native: NativeClient?
  private let pairing: IOSPhonePairingStore
  private let cache: IOSPhoneDDICache
  private let port: () async -> UInt16
  private let now: () -> Date
  private let stopNow: () -> TimeInterval?
  private let foreground: () -> Bool
  private let notifications: NotificationCenter
  private var applicationActive: Bool
  private var active: Run?
  private var starter: Task<Void, Never>?
  private(set) var state: [String: Any] = ["phase": "idle", "code": "OK"]
  var onStateChanged: (() -> Void)?

  override convenience init() {
    self.init(native: Self.makeNativeClient(), pairing: .shared, cache: .shared,
      port: {
        let raw = Bundle.main.object(forInfoDictionaryKey: "DSHPhoneRemotePairingPort")
        if let raw {
          let value = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init)
          return value.flatMap(UInt16.init(exactly:)) ?? 0
        }
        return await PhoneRemotePairingPort.resolve()
      })
  }

  init(native: NativeClient?, pairing: IOSPhonePairingStore, cache: IOSPhoneDDICache,
       port: @escaping () async -> UInt16, now: @escaping () -> Date = Date.init,
       stopNow: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now,
       foreground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
       notifications: NotificationCenter = .default) {
    self.native = native; self.pairing = pairing; self.cache = cache; self.port = port; self.now = now
    self.stopNow = stopNow; self.foreground = foreground; self.notifications = notifications
    self.applicationActive = foreground()
    super.init()
    notifications.addObserver(self, selector: #selector(stopClockWillPause),
      name: UIApplication.willResignActiveNotification, object: nil)
    notifications.addObserver(self, selector: #selector(stopClockDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(stopClockDidResume),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  deinit { notifications.removeObserver(self) }

  var isAvailable: Bool { native != nil }
  var maySwitchBackend: Bool { active == nil || (active?.terminal == true && active?.faulted != true) }
  var isReady: Bool { active?.capabilities != nil && active?.stopping == false && active?.faulted == false }
  var isFaulted: Bool { active?.faulted == true }

  /// An observation must bind to this native generation, not just the reusable
  /// application-level owner string. This ID contains no credential.
  func currentRunID(ownerID: String) -> String? {
    guard let run = active, run.ownerID == ownerID, run.pairingGeneration == pairing.generation,
      run.capabilities != nil, !run.stopping, !run.terminal, !run.faulted else { return nil }
    return run.id
  }

  func prepare(ownerID: String, allowDDIMount: Bool = false,
               current: () -> Bool) async -> Result<[String: Bool], IOSPhoneCoreFailure> {
    guard native != nil else { return .failure(.init(code: "ERR_PHONE_NATIVE_UNAVAILABLE")) }
    // 越狱通道没有配对记录这回事，准入由 IOSJailbreakDevice 自己判断。
    guard IOSJailbreakDevice.available() || pairing.hasRecord else {
      return .failure(.init(code: "ERR_PHONE_PAIRING_REQUIRED"))
    }
    var observed: Run?
    while !Task.isCancelled, current() {
      if let run = observed {
        if let failure = run.failure { return .failure(failure) }
        guard active === run, !run.stopping, !run.terminal, run.pairingGeneration == pairing.generation else {
          return .failure(.init(code: "ERR_PHONE_CANCELLED"))
        }
        if let capabilities = run.capabilities { return .success(capabilities) }
        if now() >= run.deadline {
          stop(run)
          return .failure(.init(code: "ERR_PHONE_PREPARATION_TIMEOUT"))
        }
      } else if let run = active {
        if run.faulted { return .failure(.init(code: "ERR_PHONE_STOP_UNCONFIRMED")) }
        if run.terminal { active = nil; continue }
        if run.ownerID != ownerID || run.pairingGeneration != pairing.generation { stop(run) }
        if run.stopping {
          if expireStopIfNeeded(run) || run.faulted {
            return .failure(.init(code: "ERR_PHONE_STOP_UNCONFIRMED"))
          }
        } else { observed = run }
      } else {
        let run = Run(ownerID: ownerID, pairingGeneration: pairing.generation,
          deadline: now().addingTimeInterval(allowDDIMount ? 600 : 95))
        active = run; observed = run
        begin(run, allowDDIMount: allowDDIMount)
      }
      do { try await Task.sleep(nanoseconds: 50_000_000) }
      catch { break }
    }
    if let observed, active === observed { stop(observed) }
    return .failure(.init(code: "ERR_PHONE_CANCELLED"))
  }

  func request(_ values: [String: Any], ownerID: String,
               current: () -> Bool) async -> Result<IOSPhoneCoreReply, IOSPhoneCoreFailure> {
    guard !Task.isCancelled, current(), let native, let run = active,
      run.ownerID == ownerID, run.pairingGeneration == pairing.generation,
      run.capabilities != nil, !run.stopping, !run.faulted, !run.terminal else {
      return .failure(.init(code: "ERR_PHONE_CORE_NOT_READY"))
    }
    guard run.pending == nil, run.nextRequest < UInt64.max else { return .failure(.init(code: "ERR_PHONE_BUSY")) }
    guard let bytes = try? JSONSerialization.data(withJSONObject: values), bytes.count <= 16_384,
      let operation = values["op"] as? String else { return .failure(.init(code: "ERR_PHONE_ARGUMENTS")) }
    let pending = Request(id: run.nextRequest, mutating: !["screenshot", "apps"].contains(operation))
    run.nextRequest += 1
    run.pending = pending
    let accepted = native.request(run.handle, pending.id, bytes) { [weak self, weak run] handle, id, status, text, data in
      guard let self, let run else { return }
      self.receiveResult(run, handle: handle, id: id, status: status, text: text, bytes: data)
    }
    guard accepted == 0 else {
      if run.pending === pending { run.pending = nil }
      return .failure(.init(code: Self.acceptanceCode(accepted)))
    }
    let deadline = now().addingTimeInterval(["ascii", "prepareInput"].contains(operation) ? 110 : 35)
    while true {
      guard !Task.isCancelled, current(), active === run, !run.stopping,
        !run.terminal, !run.faulted, run.pairingGeneration == pairing.generation,
        now() < deadline else {
        native.cancel(run.handle, pending.id)
        stop(run)
        // Dispatch may already have happened. The late result and terminal
        // callback still own cleanup, but this caller never retries/falls back.
        return .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      }
      // Cancellation, revocation and an inline native callback can all occur
      // before request() returns. A stored result is not authority to report a
      // success after this exact owner/call has ceased to be current.
      if let reply = pending.reply { return reply }
      do { try await Task.sleep(nanoseconds: 20_000_000) }
      catch { /* Next iteration cancels the exact request and retires its owner. */ }
    }
  }

  func stop(ownerID: String? = nil) {
    guard let run = active, ownerID == nil || ownerID == run.ownerID else { return }
    stop(run)
  }

  private func stop(_ run: Run) {
    guard active === run, !run.stopping, !run.terminal, !run.faulted else { return }
    run.stopping = true; run.capabilities = nil
    starter?.cancel(); starter = nil
    if run.handle == 0 {
      run.terminal = true; active = nil
      setState(["phase": "idle", "code": "OK"])
    } else {
      setState(["phase": "stopping", "code": "ERR_PHONE_STOPPING"])
      guard active === run, !run.terminal, !run.faulted else { return }
      // Start the foreground-only budget before calling native: an adapter can
      // report cleanup inline or synchronously notify a lifecycle transition.
      let validClock = !(applicationActive && foreground()) || advanceStopClock(run)
      native?.stop(run.handle)
      guard active === run, !run.terminal, !run.faulted else { return }
      if !validClock { faultStopTimeout(run); return }
      run.stopWatcher = Task { [weak self, weak run] in
        while !Task.isCancelled {
          do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
          guard !Task.isCancelled, let self, let run, self.active === run,
            run.stopping, !run.terminal, !run.faulted else { return }
          if self.expireStopIfNeeded(run) { return }
        }
      }
    }
  }

  /// Accumulate only intervals whose start and end are in the same active
  /// lifecycle segment. The 45 seconds exceeds Rust's 5+5+5+15 cleanup budget;
  /// scheduling and background suspension are not native cleanup evidence.
  private func advanceStopClock(_ run: Run) -> Bool {
    guard let sample = stopNow(), sample.isFinite, sample >= 0 else { return false }
    if let last = run.stopLastSample, sample < last { return false }
    if let previous = run.stopAnchor {
      guard sample >= previous else { return false }
      let elapsed = run.stopElapsed + (sample - previous)
      guard elapsed.isFinite else { return false }
      run.stopElapsed = elapsed
    }
    run.stopAnchor = sample
    run.stopLastSample = sample
    return true
  }

  @discardableResult
  private func expireStopIfNeeded(_ run: Run) -> Bool {
    guard active === run, run.stopping, !run.terminal, !run.faulted else { return false }
    guard applicationActive, foreground() else {
      // A missing/late pause notification must not make an inactive poll add
      // an uncertain interval. The normal willResignActive hook settles it.
      run.stopAnchor = nil
      return false
    }
    guard advanceStopClock(run), run.stopElapsed < 45 else {
      faultStopTimeout(run)
      return true
    }
    return false
  }

  @objc private func stopClockWillPause(_ notification: Notification) {
    guard applicationActive else { return }
    applicationActive = false
    guard let run = active, run.stopping, !run.terminal, !run.faulted else { return }
    // UIKit delivers this before leaving the active lifecycle segment. Settle
    // only an existing anchor, then discard it before the app can be suspended.
    if run.stopAnchor != nil, (!advanceStopClock(run) || run.stopElapsed >= 45) {
      faultStopTimeout(run)
    }
    run.stopAnchor = nil
  }

  @objc private func stopClockDidEnterBackground(_ notification: Notification) {
    applicationActive = false
    active?.stopAnchor = nil
  }

  @objc private func stopClockDidResume(_ notification: Notification) {
    let wasActive = applicationActive
    applicationActive = foreground()
    guard !wasActive, applicationActive else { return }
    guard let run = active, run.stopping, !run.terminal, !run.faulted else { return }
    run.stopAnchor = nil
    _ = expireStopIfNeeded(run)
  }

  private func faultStopTimeout(_ run: Run) {
    guard active === run, run.stopping, !run.terminal, !run.faulted else { return }
    run.stopWatcher?.cancel(); run.stopWatcher = nil; run.stopAnchor = nil
    run.fault = .stopTimeout; run.capabilities = nil
    run.failure = .init(code: "ERR_PHONE_STOP_UNCONFIRMED", mayHaveActed: run.pending?.mutating ?? false)
    if let pending = run.pending, pending.reply == nil {
      pending.reply = .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
    }
    run.pending = nil
    Self.resultCallbacks = Self.resultCallbacks.filter { !$0.key.hasPrefix("\(run.handle):") }
    // Keep this exact run's event callback. Only a matching native kind 2/3
    // with cleanupConfirmed=true may remove this local timeout barrier later.
    // Old requests remain retired; neither ready nor a result revives them.
    setState(["phase": "faulted", "code": "ERR_PHONE_STOP_UNCONFIRMED", "checks": run.checks])
  }

  private func begin(_ run: Run, allowDDIMount: Bool) {
    setState(["phase": "starting", "stage": "pairing", "code": "OK"])
    starter = Task { [weak self, weak run] in
      guard let self, let run else { return }
      let jailbreak = IOSJailbreakDevice.available()
      Self.trace("begin run=\(run.id) jailbreak=\(jailbreak) native=\(self.native != nil)")
      let servicePort = jailbreak ? 0 : await self.port()
      guard !Task.isCancelled, self.active === run, !run.stopping,
        run.pairingGeneration == self.pairing.generation, self.now() < run.deadline,
        let native = self.native else { return }
      guard jailbreak || servicePort != 0 else {
        run.failure = .init(code: "ERR_PHONE_CONFIGURATION"); run.terminal = true
        self.setState(["phase": "failed", "code": "ERR_PHONE_CONFIGURATION"]); return
      }
      do {
        let configuration: [String: Any] = [
          "runId": run.id, "host": "10.7.0.1", "port": servicePort,
          "allowDDIMount": allowDDIMount,
          "ddiCache": self.cache.nativeConfiguration(),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: configuration)
        guard encoded.count <= 96 * 1024 else { throw IOSPhonePairingError.tooLarge }
        let (status, handle) = try { () throws -> (Int32, UInt64) in
          // 越狱通道忽略配对记录；传空 Data 只占位，原生侧不会读它。
          if jailbreak {
            return native.start(run.id, encoded, Data()) { [weak self, weak run] handle, id, kind, text in
              guard let self, let run else { return }
              self.receive(run, handle: handle, runID: id, kind: kind, text: text)
            }
          }
          let record = try self.pairing.load()
          guard !record.isEmpty, record.count <= IOSPhonePairingRecord.maximumBytes else {
            throw IOSPhonePairingError.tooLarge
          }
          // End this local hold at synchronous start. The store may deliberately
          // share Data backing storage; resetBytes could first create a CoW copy
          // and cannot promise to erase the retained session/Keychain record.
          return native.start(run.id, encoded, record) { [weak self, weak run] handle, id, kind, text in
            guard let self, let run else { return }
            self.receive(run, handle: handle, runID: id, kind: kind, text: text)
          }
        }()
        if run.handle != 0, run.handle != handle {
          run.fault = .protocolMismatch; run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL")
        } else { run.handle = handle }
        if status != 0 || handle == 0 {
          run.failure = .init(code: Self.acceptanceCode(status)); run.terminal = true
          self.setState(["phase": "failed", "code": run.failure!.code])
        }
      } catch {
        run.failure = .init(code: (error as? IOSPhonePairingError)?.code ?? "ERR_PHONE_CONFIGURATION")
        run.terminal = true
        self.setState(["phase": "failed", "code": run.failure!.code])
      }
    }
  }

  /// 手机通道的诊断日志（	mp/phone.log）。
  ///
  /// 引擎侧只保留两行日志，失败码又都很笼统（例如 ERR_PHONE_CORE_PROTOCOL
  /// 覆盖了七八种原因），没有这个文件就只能靠读代码猜。只记状态迁移和
  /// 失败判定点，不记屏幕内容。
  static func trace(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = stamp + " " + message + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phone.log")
    if let data = line.data(using: .utf8) {
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
      } else {
        try? data.write(to: url)
      }
    }
  }

  private func receive(_ run: Run, handle: UInt64, runID: String, kind: Int32, text: String) {
    guard active === run, run.id == runID, handle != 0, !run.terminal,
      !run.faulted || run.fault == .stopTimeout else { return }
    if run.handle == 0 { run.handle = handle } // Native callbacks may precede start's return.
    Self.trace("event kind=\(kind) handle=\(handle) text=\(String(text.prefix(240)))")
    guard run.handle == handle, text.utf8.count <= 8192,
      let event = try? JSONDecoder().decode(IOSPhoneCoreEvent.self, from: Data(text.utf8)) else {
      if run.faulted { return }
      run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL"); stop(run); return
    }
    let confirmedTerminal = (kind == 2 || kind == 3) && event.cleanupConfirmed == true
    if run.fault == .stopTimeout, !confirmedTerminal, kind != 4 { return }
    // A valid terminal ACK wins even at the deadline or before a delayed tick.
    // Native kind 4 is a different, irreversible fault and is never downgraded.
    if !confirmedTerminal, kind != 4, expireStopIfNeeded(run) { return }
    if (kind == 2 || kind == 3), !confirmedTerminal {
      run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL"); stop(run); return
    }
    if let value = event.vpnReachable { run.checks["vpnReachable"] = value }
    if let value = event.pairingVerified { run.checks["pairingVerified"] = value }
    if let value = event.lockdownReady { run.checks["lockdownReady"] = value }
    if let value = event.ddiMounted { run.checks["ddiMounted"] = value }
    switch kind {
    case 0, 5:
      guard !run.stopping else { return }
      var value: [String: Any] = ["phase": "starting", "code": "OK"]
      if let stage = event.stage, ["pairing", "tunnel", "services", "verifyingAssets", "personalizing", "uploading", "mounting", "refreshingServices"].contains(stage) { value["stage"] = stage }
      if let count = event.completedBytes, count >= 0 { value["completedBytes"] = count }
      if let total = event.totalBytes, total > 0 { value["totalBytes"] = total }
      value["checks"] = run.checks; setState(value)
    case 1:
      guard !run.stopping, !run.faulted, let capabilities = event.capabilities,
        run.pairingGeneration == pairing.generation else { stop(run); return }
      run.capabilities = capabilities
      setState(["phase": "ready", "code": "OK", "capabilities": capabilities, "checks": run.checks])
    case 2, 3, 4:
      run.stopWatcher?.cancel(); run.stopWatcher = nil; run.stopAnchor = nil
      let code = Self.safeCode(event.code) ?? (kind == 2 ? "OK" : "ERR_PHONE_CORE_PROTOCOL")
      run.capabilities = nil
      run.failure = .init(code: kind == 2 ? "ERR_PHONE_CANCELLED" : code,
        variant: ["personalized", "cryptex"].contains(event.variant ?? "") ? event.variant : nil,
        mayHaveActed: event.mayHaveActed ?? (kind == 4))
      run.fault = kind == 4 ? .native : nil
      run.terminal = kind != 4
      if let pending = run.pending, pending.reply == nil {
        pending.reply = .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      }
      run.pending = nil
      Self.eventCallbacks.removeValue(forKey: run.id)
      Self.resultCallbacks = Self.resultCallbacks.filter { !$0.key.hasPrefix("\(handle):") }
      var value: [String: Any] = ["phase": kind == 2 ? "idle" : (kind == 4 ? "faulted" : "failed"), "code": code]
      if let variant = run.failure?.variant { value["variant"] = variant }
      value["checks"] = run.checks
      setState(value)
    default:
      run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL"); stop(run)
    }
  }

  private func receiveResult(_ run: Run, handle: UInt64, id: UInt64, status: Int32, text: String, bytes: Data?) {
    Self.trace("result status=\(status) bytes=\(bytes?.count ?? -1) text=\(String(text.prefix(240)))")
    guard active === run, run.handle == handle, let pending = run.pending,
      pending.id == id, pending.reply == nil else { return }
    guard !run.stopping, !run.terminal, !run.faulted,
      run.pairingGeneration == pairing.generation else {
      pending.reply = .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      run.pending = nil
      return
    }
    guard (0...3).contains(status), text.utf8.count <= 8192,
      let metadata = try? JSONDecoder().decode(IOSPhoneCoreReply.Metadata.self, from: Data(text.utf8)),
      ["read", "dispatched", "notSent", "uncertain"].contains(metadata.outcome ?? ""),
      metadata.code == nil || Self.safeCode(metadata.code) != nil,
      status == 0 || bytes == nil else {
      // 这个分支里 metadata 已经不在作用域（guard 的绑定只在成功路径可见），
      // 所以把原始文本记下来，足够看出是哪一条校验没过。
      Self.trace("protocol-reject status=\(status) bytes=\(bytes?.count ?? -1)")
      pending.reply = .failure(.init(code: "ERR_PHONE_CORE_PROTOCOL", mayHaveActed: pending.mutating))
      run.pending = nil; stop(run); return
    }
    if metadata.kind == "apps", (bytes?.count ?? 0) > 1024 * 1024 {
      pending.reply = .failure(.init(code: "ERR_PHONE_CORE_PROTOCOL")); run.pending = nil; stop(run); return
    }
    pending.reply = .success(IOSPhoneCoreReply(status: status, metadata: metadata, bytes: bytes))
    run.pending = nil
  }

  private func setState(_ value: [String: Any]) { state = value; onStateChanged?() }
  private static func safeCode(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 96,
      value.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
    return value
  }
  private static func acceptanceCode(_ status: Int32) -> String {
    switch status {
    case 1, 7: return "ERR_PHONE_ARGUMENTS"
    case 2: return "ERR_PHONE_BUSY"
    case 3: return "ERR_PHONE_STALE_REQUEST"
    case 4: return "ERR_PHONE_CORE_NOT_READY"
    case 5: return "ERR_PHONE_STOPPING"
    case 6: return "ERR_PHONE_STOP_UNCONFIRMED"
    default: return "ERR_PHONE_NATIVE_UNAVAILABLE"
    }
  }

  static func deliverEvent(handle: UInt64, runID: String, kind: Int32, text: String) {
    eventCallbacks[runID]?(handle, runID, kind, text)
  }
  static func deliverResult(handle: UInt64, requestID: UInt64, status: Int32, text: String, bytes: Data?) {
    let key = "\(handle):\(requestID)"
    let callback = resultCallbacks.removeValue(forKey: key)
    callback?(handle, requestID, status, text, bytes)
  }

  private static func makeNativeClient() -> NativeClient? {
    // 越狱通道不经过 RSD/RemoteXPC，iOS 15 也能用；可用时优先于原来的两条通道。
    if let jailbreak = IOSJailbreakDevice.makeNativeClient() { return jailbreak }
    #if DSH_PHONE_SELF_RUNNER
    guard let identity = phoneCoreString(dsh_phone_core_build_identity(), limit: 128),
      identity == "dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065" else { return nil }
    return NativeClient(start: { runID, data, pairing, callback in
      eventCallbacks[runID] = callback
      var handle: UInt64 = 0
      let status = data.withUnsafeBytes { raw in
        pairing.withUnsafeBytes { record in
          dsh_phone_core_start_bytes(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
            record.bindMemory(to: UInt8.self).baseAddress, record.count, phoneCoreEventCallback, &handle)
        }
      }
      if status != 0 { eventCallbacks.removeValue(forKey: runID) }
      return (status, handle)
    }, request: { handle, requestID, data, callback in
      let key = "\(handle):\(requestID)"
      resultCallbacks[key] = callback
      let status = data.withUnsafeBytes { raw in
        dsh_phone_core_request(handle, requestID, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, phoneCoreResultCallback)
      }
      if status != 0 { resultCallbacks.removeValue(forKey: key) }
      return status
    }, cancel: { dsh_phone_core_cancel($0, $1) }, stop: { dsh_phone_core_stop($0) })
    #else
    return nil
    #endif
  }
  // MARK: - 真后台判断

  /// 当前真正显示在屏幕上的 App 的 bundle id；查不到时返回 nil。
  ///
  /// 越狱设备上装了「真后台」类 tweak 时，App 切走后
  /// `UIApplication.applicationState` 可能仍然是 active，用它判断
  /// 「我是不是前台」会得到错误答案。这里直接问 SpringBoard 谁在前台。
  static func frontmostBundleID() -> String? {
    if let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                           RTLD_NOW) {
      defer { dlclose(handle) }
      if let raw = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier") {
        typealias Fn = @convention(c) () -> Unmanaged<CFString>?
        if let value = unsafeBitCast(raw, to: Fn.self)()?.takeRetainedValue() {
          let bundle = value as String
          if !bundle.isEmpty { return bundle }
        }
      }
    }
    // 退一步用 LSApplicationWorkspace，不需要 SpringBoard 权限。
    guard let main = dlopen(nil, RTLD_NOW), let rawSend = dlsym(main, "objc_msgSend") else { return nil }
    typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
    let send0 = unsafeBitCast(rawSend, to: MsgSend0.self)
    guard let cls = NSClassFromString("LSApplicationWorkspace") else { return nil }
    guard let workspace = send0(cls, NSSelectorFromString("defaultWorkspace")) else { return nil }
    guard let app = send0(workspace, NSSelectorFromString("frontmostApplication")) else { return nil }
    return send0(app, NSSelectorFromString("bundleIdentifier")) as? String
  }

  /// 别的 App 正占据屏幕——也就是 DSH Go 不在前台。
  ///
  /// 先看真实前台 App；查不到时退回系统状态判断。装了「真后台」tweak
  /// 时前者仍然准确，而后者会把 App 误报为前台。
  static var otherAppInFront: Bool {
    if let front = frontmostBundleID() { return front != Bundle.main.bundleIdentifier }
    return UIApplication.shared.applicationState == .background
  }

  /// 不需要宠物画中画也能在后台继续工作。
  ///
  /// 真后台 tweak 保住进程时，宠物画中画不是必须的。这里不再要求「此刻别的
  /// App 在前台」：那是抓屏前的检查（IOSPhoneCoreActions）负责的事，放在这里
  /// 只会让用户在自己的聊天界面里说「读屏」时被拦住，然后被要求去开画中画。
  /// 因此只确认设备解锁——真后台插件负责让进程活下去。
  static var backgroundKeepAliveAvailable: Bool {
    UIApplication.shared.isProtectedDataAvailable
  }

}

// MARK: - 越狱通道（并入同一文件，随 Runner target 一起编译）

// 越狱通道：在越狱设备上直接注入 HID 事件并抓屏，不依赖 iOS 17 的 RSD/RemoteXPC。
//
// 这是同一套 NativeClient 契约的第三个实现：上层的 IOSPhoneCoreActions 完全
// 不知道底下换了一条路，配对、隧道、DDI 这些概念在这里都不存在。
//
// 硬性前提（缺一不可）：
//   - 二进制带越狱权限（platform-application / no-sandbox），否则读不到 /var/jb；
//   - UIKit 的 UIGetScreenImage 与 IOKit 的 IOHIDEvent* 符号都能解析。
// 任何一项缺失都让整条通道不可用，绝不降级成“看起来成功”。

final class IOSJailbreakDevice: @unchecked Sendable {
  static let shared = IOSJailbreakDevice()

  private struct Symbols {
    let screenImage: (@convention(c) () -> Unmanaged<CGImage>?)?
    let createScreenImage: (@convention(c) () -> Unmanaged<UIImage>?)?
    let hidCreate: (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
                                   UInt32, UInt32, UInt32, UInt8,
                                   Double, Double, Double, Double, UInt32, UInt32) -> Unmanaged<CFTypeRef>?)?
    let hidKeyCreate: (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt8, UInt32) -> Unmanaged<CFTypeRef>?)?
    let hidSetFloat: (@convention(c) (CFTypeRef, UInt32, Double) -> Void)?
    let hidSystemCreate: (@convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?)?
    let hidDispatch: (@convention(c) (CFTypeRef, CFTypeRef) -> Void)?
  }

  private static let symbols: Symbols = {
    let uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_LOCAL)
    let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL)
    let main = dlopen(nil, RTLD_NOW | RTLD_LOCAL)

    func look<T>(_ name: String, _ type: T.Type, _ handles: [UnsafeMutableRawPointer?]) -> T? {
      for handle in handles {
        guard let handle, let raw = dlsym(handle, name) else { continue }
        return unsafeBitCast(raw, to: T.self)
      }
      return nil
    }

    return Symbols(
      screenImage: look("UIGetScreenImage", (@convention(c) () -> Unmanaged<CGImage>?).self, [uikit, main]),
      createScreenImage: look("_UICreateScreenUIImage", (@convention(c) () -> Unmanaged<UIImage>?).self,
        [uikit, main]),
      hidCreate: look("IOHIDEventCreateDigitizerEvent",
        (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
                         UInt32, UInt32, UInt32, UInt8,
                         Double, Double, Double, Double, UInt32, UInt32) -> Unmanaged<CFTypeRef>?).self,
        [iokit, main]),
      hidKeyCreate: look("IOHIDEventCreateKeyboardEvent",
        (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt8, UInt32) -> Unmanaged<CFTypeRef>?).self,
        [iokit, main]),
      hidSetFloat: look("IOHIDEventSetFloatValue", (@convention(c) (CFTypeRef, UInt32, Double) -> Void).self,
        [iokit, main]),
      hidSystemCreate: look("IOHIDEventSystemClientCreate",
        (@convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?).self, [iokit, main]),
      hidDispatch: look("IOHIDEventSystemClientDispatchEvent",
        (@convention(c) (CFTypeRef, CFTypeRef) -> Void).self, [iokit, main]))
  }()

  /// 提供给上层的实际能力。只有这里声明 true 的动作才会被允许派发。
  /// 文本输入（ascii/paste）依赖剪贴板 staging 与回前台流程，第一版不声明。
  static func capabilities() -> [String: Bool] {
    ["touch": true, "key": true, "launch": true, "apps": true, "type": true]
  }

  /// 越狱权限探测：带 no-sandbox 时进程能读到越狱根目录。
  private static func processHasJailbreakPrivilege() -> Bool {
    ["/var/jb", "/var/jb/usr", "/var/jb/Library", "/private/preboot"].contains {
      FileManager.default.fileExists(atPath: $0)
    }
  }

  /// 读本进程自己的 entitlements。越狱构建里可能只带 HID 权限而不带 no-sandbox，
  /// 那种情况下读不到 /var/jb，但注入能力是有的。
  private static func hasHIDEntitlement() -> Bool {
    typealias CreateTask = @convention(c) (CFAllocator?) -> CFTypeRef?
    typealias CopyValue = @convention(c) (CFTypeRef?, CFString, UnsafeMutableRawPointer?) -> CFTypeRef?
    guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
      return false
    }
    defer { dlclose(handle) }
    guard let rawCreate = dlsym(handle, "SecTaskCreateFromSelf"),
          let rawCopy = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return false }
    let create = unsafeBitCast(rawCreate, to: CreateTask.self)
    let copy = unsafeBitCast(rawCopy, to: CopyValue.self)
    guard let task = create(kCFAllocatorDefault) else { return false }
    let keys = ["com.apple.private.hid.client.event-dispatch",
                "com.apple.private.security.no-sandbox"]
    for key in keys {
      if let value = copy(task, key as CFString, nil) {
        if CFGetTypeID(value) == CFBooleanGetTypeID(),
           CFBooleanGetValue((value as! CFBoolean)) { return true }
        if CFGetTypeID(value) == CFStringGetTypeID() { return true }
      }
    }
    return false
  }

  /// 通道是否可用。
  ///
  /// 只把 HID 注入所需的三个符号当硬性条件：抓屏函数在不同 iOS 版本上
  /// 名字不一样，拿不到不该把整条通道判死。权限信号（越狱根目录或
  /// entitlement）拿不到时也放行——真失败会由具体调用明确报错，
  /// 总比在设置页永远打不开强。
  static func available() -> Bool {
    let s = symbols
    guard s.hidCreate != nil, s.hidSystemCreate != nil, s.hidDispatch != nil else { return false }
    return true
  }

  // MARK: - 状态

  private let lock = NSLock()
  private var nextFrame: UInt64 = 1
  private var lastFrameID: String?
  private var running = false
  private var hidClient: Unmanaged<CFTypeRef>?
  private var sink: IOSPhoneCoreDevice.EventSink?
  private var runID: String?

  private init() {}

  // MARK: - NativeClient 适配

  /// 越狱通道可用时替换掉 RSD 那一套；不可用返回 nil，让原有两条通道照常工作。
  static func makeNativeClient() -> IOSPhoneCoreDevice.NativeClient? {
    guard available() else { return nil }
    let device = shared
    return IOSPhoneCoreDevice.NativeClient(
      start: { runID, _configuration, _pairing, sink in
        device.begin(runID: runID, sink: sink)
        return (0, 1)
      },
      request: { handle, requestID, data, sink in
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          Task { @MainActor in
            sink(handle, requestID, 2, Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), nil)
          }
          return 0
        }
        let outcome = device.perform(values)
        Task { @MainActor in sink(handle, requestID, outcome.status, outcome.metadata, outcome.bytes) }
        return 0
      },
      cancel: { _, _ in },
      stop: { handle in
        device.end(handle: handle)
      })
  }

  private func begin(runID: String, sink: @escaping IOSPhoneCoreDevice.EventSink) {
    lock.lock()
    self.runID = runID
    self.sink = sink
    running = true
    lock.unlock()
    // 让上层的 start 先返回并落好 handle，再宣布就绪。
    Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: 40_000_000)
      self.lock.lock()
      let live = self.running
      let id = self.runID
      let callback = self.sink
      self.lock.unlock()
      guard live, let id, let callback else { return }
      callback(1, id, 1, Self.json(["capabilities": Self.capabilities()]))
    }
  }

  private func end(handle: UInt64) {
    lock.lock()
    let callback = sink
    let id = runID
    running = false
    sink = nil
    runID = nil
    lock.unlock()
    guard let callback, let id else { return }
    Task { @MainActor in
      callback(handle, id, 2, Self.json(["code": "OK", "cleanupConfirmed": true]))
    }
  }

  // MARK: - 动作

  private struct Outcome {
    let status: Int32
    let metadata: String
    let bytes: Data?
  }

  private func perform(_ values: [String: Any]) -> Outcome {
    guard let op = values["op"] as? String else { return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil) }
    switch op {
    case "screenshot": return capture()
    case "apps": return apps()
    case "tap": return tap(values)
    case "swipe": return swipe(values)
    case "key": return key(values)
    case "launch": return launch(values)
    case "prepareInput":
      // 上层在读屏/打开应用前先发这个，用来确认输入通道可用。
      // 越狱通道直接注入 HID，没有需要预热的输入服务，回执成功即可。
      return Outcome(status: 0, metadata: Self.json(["outcome": "read"]), bytes: nil)
    case "paste", "ascii":
      // 文本输入依赖剪贴板 staging 和回到前台，第一版不声称支持。
      return asciiOrPaste(op, values)
    default:
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_UNSUPPORTED"]), bytes: nil)
    }
  }

  private func capture() -> Outcome {
    guard let image = screenImage() else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_CAPTURE"]), bytes: nil)
    }
    guard let png = image.pngData() else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_CAPTURE"]), bytes: nil)
    }
    lock.lock()
    nextFrame &+= 1
    // 上层的读屏解码器用 `UUID(uuidString:)` 校验 nativeFrameId，递增序号会被
    // 判成无效帧，于是每次读屏都返回 ERR_PHONE_SCREEN_INVALID。这里必须给 UUID。
    let frameID = UUID().uuidString
    lastFrameID = frameID
    lock.unlock()
    let w = Int(image.size.width * image.scale)
    let h = Int(image.size.height * image.scale)
    // 上层解析读屏结果时必须有 interfaceOrientation，缺了会直接判失败。
    let orientation = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.interfaceOrientation.rawValue ?? 1
    let meta: [String: Any] = ["outcome": "read", "kind": "screenshot",
                              "width": w, "height": h, "nativeFrameId": frameID,
                              "interfaceOrientation": orientation,
                              "contentType": "image/png"]
    return Outcome(status: 0, metadata: Self.json(meta), bytes: png)
  }

  private func apps() -> Outcome {
    // 上层按 [String: [[String: String]]] 严格解码，多一个非字符串字典的键
    // 就会整体解码失败并报 ERR_PHONE_CORE_PROTOCOL，所以这里只放 apps。
    let payload: [String: Any] = ["apps": installedApplications()]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_CAPTURE"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "read", "kind": "apps"]), bytes: data)
  }

  /// 内置的已装应用兜底表：沙盒里的 LSApplicationWorkspace 经常返回空，
  /// 有了它「打开微信」这类按名字找包名的请求仍然能解析。
  private static let builtinApplications: [(name: String, id: String)] = [
    ("19楼", "com.19lou.nineteenlou"),
    ("21财经", "com.21newmedia.ePaper-iPhone"),
    ("3d Scanner App", "com.laan.labs.3dScannerPro"),
    ("AmbientLight", "com.bigpanda.development.Ex-USB"),
    ("Apps Manager", "com.tigisoftware.ADManager"),
    ("Authenticator", "com.microsoft.azureauthenticator"),
    ("Books", "com.apple.iBooks"),
    ("Calendar", "com.apple.mobilecal"),
    ("ChatX", "com.app.ChatGPTX"),
    ("Chrome", "com.google.chrome.ios"),
    ("CocoaTop", "ru.domo.cocoatop64"),
    ("Compass", "com.apple.compass"),
    ("Contacts", "com.apple.MobileAddressBook"),
    ("DAMA", "tech.baye.placeholder"),
    ("DJI GO 4", "com.dji.go"),
    ("DSH Go", "io.github.ccch1mneyyy.dshgo"),
    ("DeepSeek", "com.deepseek.chat"),
    ("Discord", "com.hammerandchisel.discord"),
    ("DowngradeApp", "com.netskao.downgradeapp"),
    ("ESign", "xyz.yyyue.esign"),
    ("FaceTime", "com.apple.facetime"),
    ("Files", "com.apple.DocumentsApp"),
    ("Filza", "com.tigisoftware.Filza"),
    ("Flex 3 Beta", "Flex3"),
    ("GTA Car Tracker", "com.icraze.gtatracker"),
    ("GitHub", "com.github.stormbreaker.prod"),
    ("HashPhotos", "com.kobaltlab.HashPhotos"),
    ("Home", "com.apple.Home"),
    ("IMASS", "www.glinkwin.com.imass"),
    ("Infuse", "com.firecore.infuse"),
    ("JetSign", "com.jetsign.app"),
    ("Kimi", "com.moonshot.kimichat"),
    ("Kwai", "com.jiangjia.gif"),
    ("LOY SPACE", "com.yskd.loywf"),
    ("LocalSend", "org.localsend.localsendApp"),
    ("Maps", "com.apple.Maps"),
    ("Measure", "com.apple.measure"),
    ("Mi Router", "com.xiaomi.miwifi"),
    ("MiHome", "com.xiaomi.mihome"),
    ("MotionSource", "cc.shiftinv.motionsource"),
    ("NFC门禁", "com.amywhile.Aemulo2"),
    ("Notes", "com.apple.mobilenotes"),
    ("PS", "com.adobe.PSMobile"),
    ("PayPal", "com.yourcompany.PPClient"),
    ("Phone", "com.apple.mobilephone"),
    ("Piiico", "com.abighead.pico"),
    ("Print Utility", "jp.co.fujixerox.print.PrintUtil"),
    ("QQ", "com.tencent.mqq"),
    ("QQ邮箱", "com.tencent.qqmail"),
    ("Quantumult X", "com.crossutility.quantumult-x"),
    ("RHXPlus", "com.rhxled.LED-CRP"),
    ("Reminders", "com.apple.reminders"),
    ("RingTonesManager", "com.netskao.ringtonesmanager"),
    ("SMRTE", "com.rsl.LtFuture"),
    ("SMRTE C", "com.laitecn.smarthome"),
    ("Saily", "wiki.qaq.chromatic.release"),
    ("Scrcpy Remote", "com.mobile.scrcpy-ios"),
    ("Shadowrocket", "com.liguangming.Shadowrocket"),
    ("Shortcuts", "com.apple.shortcuts"),
    ("Sileo", "org.coolstar.SileoStore"),
    ("SpeedTest", "co.allconnected.speedtest"),
    ("Stiiitch", "com.abighead.stiiitch"),
    ("Stream", "com.fish.stream"),
    ("Support", "com.apple.supportapp"),
    ("TV Assist", "com.e2esoft.TV-Assist"),
    ("Telegram", "ph.telegra.Telegraph"),
    ("Terminal#", "com.making-app.RemTerm"),
    ("TestFlight", "com.apple.TestFlight"),
    ("TikTok", "com.zhiliaoapp.musically"),
    ("Tips", "com.apple.tips"),
    ("TrollDecrypt2", "com.app.troll.TrollDecrypt2"),
    ("TrollFools", "wiki.qaq.TrollFools"),
    ("TrollLEDs", "com.ps.TrollLEDs"),
    ("TrollNonce", "com.opa334.trollnonce"),
    ("TrollStore", "com.opa334.TrollStore"),
    ("UTM", "com.utmapp.UTM"),
    ("Varlens", "com.auramarker.varlens"),
    ("Video Compressor", "com.rockybrain.videocompressor"),
    ("VoiceMemos", "com.apple.VoiceMemos"),
    ("WaterPurifier", "com.yunmi.vmall"),
    ("Weather", "com.apple.weather"),
    ("WidgetArt", "com.ziheng.widgetart"),
    ("Widgy", "com.woodsign.Widgy"),
    ("Wind金融终端", "com.wind.info.iphone"),
    ("Wink", "com.meitu.wink"),
    ("X", "com.atebits.Tweetie2"),
    ("XinaA15", "com.xina.jailbreak"),
    ("YouTube", "com.google.ios.youtube"),
    ("atvTools", "dev.vodik7.atvtools.atvTools"),
    ("e-Control", "cn.com.broadlink.e-Control"),
    ("waycam", "com.HisMobiCam.iOS"),
    ("东新社", "com.gelonghui.dxpress"),
    ("东方财富", "com.eastmoney.iphone"),
    ("中信证券", "com.tzt.zxsc"),
    ("中国联通", "com.chinaunicom.mobilebusiness"),
    ("中国银行", "com.boc.BOCMBCI"),
    ("交管12123", "com.tmri.12123"),
    ("京东", "com.360buy.jdmobile"),
    ("什么值得买", "com.smzdm.client.ios"),
    ("体重日记", "com.kproduce.weightdiary"),
    ("元宝", "com.tencent.hunyuan.app.chat"),
    ("剪映", "com.lemon.lv"),
    ("千问", "com.aliyun.ios.tongyi"),
    ("华尔街见闻Int", "com.wallstreetcn.news.global"),
    ("双摄相机", "com.gejiangs.DoubleCamare"),
    ("叮咚", "com.eques.DoorBell"),
    ("同花顺", "cn.com.10jqka.IHexin"),
    ("哔哩哔哩", "tv.danmaku.bilianime"),
    ("墨迹天气", "com.moji.MojiWeather"),
    ("复盘盒子", "com.fupanhezi.app"),
    ("天猫", "com.taobao.tmall"),
    ("央视频", "com.cctv.yangshipin.app.iphone"),
    ("夸克", "com.quark.browser"),
    ("威锋", "com.feng.New.WPForumClient"),
    ("安居客", "com.anjuke.anjuke"),
    ("小旋风收音机", "com.xiaoxuanfeng.ILoveRadio"),
    ("小白虾", "com.tzrl.tzrl"),
    ("小米音箱", "com.xiaomi.mico"),
    ("小黄历", "com.PP.ChinaCalendar"),
    ("崩溃日志", "com.foxfort.KrashKopApp"),
    ("巨潮资讯", "com.cninfo.juchaozixun"),
    ("开盘啦", "com.kaipanla.www"),
    ("录屏变声", "com.enjoy.screen.recorder"),
    ("录音专家", "cn.recordrabbit.www"),
    ("微信", "com.tencent.xin"),
    ("悬浮窗", "com.news.FirstScreen"),
    ("抖音", "com.ss.iphone.ugc.Aweme"),
    ("招商银行", "com.cmbchina.MPBBank"),
    ("拼多多", "com.xunmeng.pinduoduo"),
    ("支付宝", "com.alipay.iphoneclient"),
    ("新华社", "com.xinhuamm.d0001"),
    ("新浪财经", "com.sina.stock"),
    ("无人炊", "com.tempetekliy.dicook"),
    ("有条下载", "com.paperclipglobal.LineGet"),
    ("欢乐斗地主", "com.tencent.ioshlddz"),
    ("比亚迪", "com.byd.BYDi"),
    ("浙里办", "zjzwfw.gov.cn"),
    ("淘宝", "com.taobao.taobao4iphone"),
    ("淘股吧", "cn.com.taoguba.Taoguba-App-Client"),
    ("清理工具", "com.ivanobilenchi.icleaner2"),
    ("灵光", "com.antgroup.leopard.ios"),
    ("特来电", "com.tgood.gotocharge"),
    ("电池助手", "com.callassist.batteryinfolist"),
    ("电视超人", "com.xiaomi.tvassistant"),
    ("番茄小说", "com.dragon.read"),
    ("百度地图", "com.baidu.map"),
    ("百度网盘", "com.baidu.netdiskVIP"),
    ("百度输入法", "com.baidu.inputMethod"),
    ("盒马", "com.wdk.hmxs"),
    ("硕眼探企", "com.amarsoft.irisk"),
    ("网上国网", "com.wsgw.zsdl95598"),
    ("美团", "com.meituan.imeituan"),
    ("美图秀秀", "com.meitu.mtxx"),
    ("美颜相机", "com.meitu.myxj"),
    ("虚拟定位", "com.mika.LocationSimulation"),
    ("蚂蚁阿福", "com.antgroup.aijk.iphone"),
    ("蛋蛋不语", "com.danbo.dbxq"),
    ("血压管理", "com.eulersoft.bloodpressurediary"),
    ("装修记账", "com.mobivans.DecorationAccount"),
    ("计算器", "com.apple.calculator"),
    ("证券时报", "com.zqsbs.NewMedia"),
    ("豆包", "com.bot.doubao"),
    ("财联社", "cn.lanjing.cailianshe"),
    ("账号本子", "com.wei.account"),
    ("迅雷Beta", "com.xunlei.iosthunder"),
    ("酷我音乐", "com.yeelion.kwplayer"),
    ("金十数据", "com.jin10.lgd"),
    ("问小白", "com.wenxiaobai.app"),
    ("闲鱼", "com.taobao.fleamarket"),
    ("阿里云盘", "com.alicloud.smartdrive"),
    ("雪球", "com.xueqiu"),
    ("韭研公社", "com.jbangit.LeekCommune"),
    ("高德地图", "com.autonavi.amap"),
  ]

  /// 用 LSApplicationWorkspace 列已装应用。
  ///
  /// 这条私有接口不依赖文件系统权限，所以没有 no-sandbox 也能拿到列表，
  /// 上层才能把「微信」这种名字解析成 bundle id。
  private func installedApplications() -> [[String: String]] {
    // LSApplicationWorkspace 在 MobileCoreServices 里，没加载时 NSClassFromString 会返回 nil。
    for path in ["/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
                 "/System/Library/Frameworks/CoreServices.framework/CoreServices"] {
      dlopen(path, RTLD_NOW)
    }
    // 沙盒里常拿不到 objc_msgSend 或列表，这时用内置表兜底。
    let fallback: () -> [[String: String]] = { Self.builtinApplications.map { ["name": $0.name, "id": $0.id] } }
    guard let handle = dlopen(nil, RTLD_NOW), let rawSend = dlsym(handle, "objc_msgSend") else {
      return fallback()
    }
    typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
    typealias MsgSend1 = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    let send0 = unsafeBitCast(rawSend, to: MsgSend0.self)
    let send1 = unsafeBitCast(rawSend, to: MsgSend1.self)

    guard let cls = NSClassFromString("LSApplicationWorkspace") else { return fallback() }
    guard let workspace = send0(cls, NSSelectorFromString("defaultWorkspace")) else { return fallback() }
    guard let list = send1(workspace, NSSelectorFromString("allInstalledApplications"), nil) as? [AnyObject] else {
      return fallback()
    }
    let idSelector = NSSelectorFromString("bundleIdentifier")
    let nameSelector = NSSelectorFromString("localizedName")
    var result: [[String: String]] = []
    result.reserveCapacity(list.count)
    for item in list {
      guard let identifier = send0(item, idSelector) as? String, !identifier.isEmpty,
            identifier.utf8.count <= 255 else { continue }
      let name = (send0(item, nameSelector) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
      result.append(["name": name, "id": identifier])
    }
    // 列表拿到了但一条都解析不出来，同样退回内置表。
    if result.isEmpty { return fallback() }
    return result.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
  }

  private func tap(_ values: [String: Any]) -> Outcome {
    guard let x = (values["x"] as? NSNumber)?.doubleValue, let y = (values["y"] as? NSNumber)?.doubleValue,
          let size = screenSize() else {
      return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil)
    }
    guard injectTap(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height) else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_DISPATCH"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "dispatched"]), bytes: nil)
  }

  private func swipe(_ values: [String: Any]) -> Outcome {
    guard let fx = (values["fromX"] as? NSNumber)?.doubleValue, let fy = (values["fromY"] as? NSNumber)?.doubleValue,
          let tx = (values["toX"] as? NSNumber)?.doubleValue, let ty = (values["toY"] as? NSNumber)?.doubleValue,
          let size = screenSize() else {
      return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil)
    }
    guard injectSwipe(from: CGPoint(x: fx * size.width, y: fy * size.height),
                      to: CGPoint(x: tx * size.width, y: ty * size.height)) else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_DISPATCH"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "dispatched"]), bytes: nil)
  }

  private func key(_ values: [String: Any]) -> Outcome {
    guard let name = values["key"] as? String else {
      return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil)
    }
    let ok: Bool
    switch name {
    case "home": ok = suspendFrontmost()
    default: ok = false
    }
    guard ok else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_UNSUPPORTED"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "dispatched"]), bytes: nil)
  }

  private func launch(_ values: [String: Any]) -> Outcome {
    guard let bundleID = values["bundleId"] as? String, !bundleID.isEmpty else {
      return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil)
    }
    guard launchApplication(bundleID) else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_LAUNCH"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "dispatched"]), bytes: nil)
  }

  // MARK: - 抓屏

  private func screenImage() -> UIImage? {
    // 越狱环境里最先试 UIKit 的私有整屏截图，它在 iOS 15 上仍然存在。
    if let raw = Self.symbols.createScreenImage?() {
      if let image = raw.takeRetainedValue() as UIImage? { return image }
    }
    if let raw = Self.symbols.screenImage?() {
      if let cg = raw.takeRetainedValue() as CGImage? { return UIImage(cgImage: cg) }
    }
    // 回退：只能截本 App 自己的窗口，用于证明通道起码通了一半。
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
      .filter { !$0.isHidden && $0.windowLevel == .normal }
    guard let window = windows.first, window.bounds.width > 0 else { return nil }
    return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
  }

  private func screenSize() -> CGSize? {
    let bounds = UIScreen.main.bounds
    return bounds.width > 0 && bounds.height > 0 ? bounds.size : nil
  }

  // MARK: - HID 注入

  private func client() -> CFTypeRef? {
    lock.lock(); defer { lock.unlock() }
    if let existing = hidClient { return existing.takeUnretainedValue() }
    guard let made = Self.symbols.hidSystemCreate?(kCFAllocatorDefault) else { return nil }
    hidClient = made
    return made.takeUnretainedValue()
  }

  private func digitizer(x: CGFloat, y: CGFloat, touched: Bool) -> CFTypeRef? {
    guard let create = Self.symbols.hidCreate else { return nil }
    guard let raw = create(kCFAllocatorDefault, mach_absolute_time(),
                           2, 0, 0, 0, 0, 0, 0, touched ? 1 : 0,
                           Double(x), Double(y), 0, 0, 0, 0) else { return nil }
    let event = raw.takeRetainedValue()
    Self.symbols.hidSetFloat?(event, 0x0C, Double(x))
    Self.symbols.hidSetFloat?(event, 0x0D, Double(y))
    return event
  }

  private func send(_ event: CFTypeRef?) {
    guard let event, let c = client(), let dispatch = Self.symbols.hidDispatch else { return }
    dispatch(c, event)
  }

  private func injectTap(x: CGFloat, y: CGFloat) -> Bool {
    guard let down = digitizer(x: x, y: y, touched: true) else { return false }
    send(down)
    usleep(60_000)
    if let up = digitizer(x: x, y: y, touched: false) { send(up) }
    return true
  }

  private func injectSwipe(from: CGPoint, to: CGPoint) -> Bool {
    guard let start = digitizer(x: from.x, y: from.y, touched: true) else { return false }
    send(start)
    let steps = 12
    for index in 1...steps {
      let t = CGFloat(index) / CGFloat(steps)
      if let move = digitizer(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, touched: true) {
        send(move)
      }
      usleep(12_000)
    }
    if let end = digitizer(x: to.x, y: to.y, touched: false) { send(end) }
    return true
  }

  // MARK: - 键盘输入

  /// US 布局的 HID 使用码。中文等非 ASCII 字符走剪贴板粘贴，不在这里。
  private static let keyMap: [Character: (usage: UInt32, shift: Bool)] = [
    "a": (0x04, false), "b": (0x05, false), "c": (0x06, false), "d": (0x07, false),
    "e": (0x08, false), "f": (0x09, false), "g": (0x0A, false), "h": (0x0B, false),
    "i": (0x0C, false), "j": (0x0D, false), "k": (0x0E, false), "l": (0x0F, false),
    "m": (0x10, false), "n": (0x11, false), "o": (0x12, false), "p": (0x13, false),
    "q": (0x14, false), "r": (0x15, false), "s": (0x16, false), "t": (0x17, false),
    "u": (0x18, false), "v": (0x19, false), "w": (0x1A, false), "x": (0x1B, false),
    "y": (0x1C, false), "z": (0x1D, false),
    "1": (0x1E, false), "2": (0x1F, false), "3": (0x20, false), "4": (0x21, false),
    "5": (0x22, false), "6": (0x23, false), "7": (0x24, false), "8": (0x25, false),
    "9": (0x26, false), "0": (0x27, false),
    " ": (0x2C, false), "-": (0x2D, false), "=": (0x2E, false), "[": (0x2F, false),
    "]": (0x30, false), "\\": (0x31, false), ";": (0x33, false), "'": (0x34, false),
    "`": (0x35, false), ",": (0x36, false), ".": (0x37, false), "/": (0x38, false),
    "A": (0x04, true), "B": (0x05, true), "C": (0x06, true), "D": (0x07, true),
    "E": (0x08, true), "F": (0x09, true), "G": (0x0A, true), "H": (0x0B, true),
    "I": (0x0C, true), "J": (0x0D, true), "K": (0x0E, true), "L": (0x0F, true),
    "M": (0x10, true), "N": (0x11, true), "O": (0x12, true), "P": (0x13, true),
    "Q": (0x14, true), "R": (0x15, true), "S": (0x16, true), "T": (0x17, true),
    "U": (0x18, true), "V": (0x19, true), "W": (0x1A, true), "X": (0x1B, true),
    "Y": (0x1C, true), "Z": (0x1D, true),
    "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true),
    "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
    "(": (0x26, true), ")": (0x27, true), "_": (0x2D, true), "+": (0x2E, true),
    "{": (0x2F, true), "}": (0x30, true), "|": (0x31, true), ":": (0x33, true),
    "\"": (0x34, true), "~": (0x35, true), "<": (0x36, true), ">": (0x37, true),
    "?": (0x38, true),
  ]

  private static let keyReturn: UInt32 = 0x28
  private static let keyShift: UInt32 = 0xE1
  private static let keyCommand: UInt32 = 0xE3

  private func keyEvent(_ usage: UInt32, down: Bool) -> CFTypeRef? {
    guard let create = Self.symbols.hidKeyCreate else { return nil }
    return create(kCFAllocatorDefault, mach_absolute_time(), 0x07, usage, down ? 1 : 0, 0)?.takeRetainedValue()
  }

  /// 按下并松开一个键；需要 Shift 时把左右 Shift 一起按下再抬起。
  private func pressKey(_ usage: UInt32, shift: Bool) {
    if shift, let modifier = keyEvent(Self.keyShift, down: true) { send(modifier) }
    if let down = keyEvent(usage, down: true) { send(down) }
    usleep(12_000)
    if let up = keyEvent(usage, down: false) { send(up) }
    if shift, let modifier = keyEvent(Self.keyShift, down: false) { send(modifier) }
    usleep(12_000)
  }

  private func typeText(_ text: String) -> Bool {
    guard Self.symbols.hidKeyCreate != nil else { return false }
    var typed = 0
    for character in text {
      if character == "\n" {
        pressKey(Self.keyReturn, shift: false)
        typed += 1
        continue
      }
      guard let mapped = Self.keyMap[character] else { continue }
      pressKey(mapped.usage, shift: mapped.shift)
      typed += 1
    }
    return typed > 0
  }

  /// 中文等非 ASCII 文本靠这里：调用方已经把文字放进剪贴板，这里只发 ⌘V。
  private func pasteClipboard() -> Bool {
    guard Self.symbols.hidKeyCreate != nil else { return false }
    if let command = keyEvent(Self.keyCommand, down: true) { send(command) }
    usleep(20_000)
    if let v = keyEvent(0x19, down: true) { send(v) }
    usleep(20_000)
    if let v = keyEvent(0x19, down: false) { send(v) }
    usleep(20_000)
    if let command = keyEvent(Self.keyCommand, down: false) { send(command) }
    return true
  }

  private func asciiOrPaste(_ op: String, _ values: [String: Any]) -> Outcome {
    let ok: Bool
    if op == "paste" {
      ok = pasteClipboard()
    } else {
      guard let text = values["text"] as? String, !text.isEmpty else {
        return Outcome(status: 2, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_ARGUMENTS"]), bytes: nil)
      }
      ok = typeText(text)
    }
    guard ok else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_UNSUPPORTED"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "dispatched"]), bytes: nil)
  }

  // MARK: - SpringBoard 私有接口

  private func withSpringBoard<T>(_ body: (UnsafeMutableRawPointer) -> T?) -> T? {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                              RTLD_NOW) else { return nil }
    defer { dlclose(handle) }
    return body(handle)
  }

  private func suspendFrontmost() -> Bool {
    withSpringBoard { handle in
      guard let raw = dlsym(handle, "SBSSuspendFrontmostApplication") else { return false }
      typealias Fn = @convention(c) (CFString) -> Void
      unsafeBitCast(raw, to: Fn.self)("" as CFString)
      return true
    } ?? false
  }

  private func launchApplication(_ bundleID: String) -> Bool {
    // 先试 SpringBoard 的私有入口，它在越狱环境下通常可用。
    let viaSpringBoard: Bool = withSpringBoard { handle in
      guard let raw = dlsym(handle, "SBSLaunchApplicationWithIdentifier") else { return false }
      typealias Fn = @convention(c) (CFString, Bool) -> Int32
      return unsafeBitCast(raw, to: Fn.self)(bundleID as CFString, false) == 0
    } ?? false
    if viaSpringBoard { return true }
    // 退一步用 LSApplicationWorkspace，它同样是私有接口但不需要 SpringBoard 权限。
    guard let main = dlopen(nil, RTLD_NOW), let rawSend = dlsym(main, "objc_msgSend") else {
      return false
    }
    typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
    typealias MsgSendBool = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let send0 = unsafeBitCast(rawSend, to: MsgSend0.self)
    let sendBool = unsafeBitCast(rawSend, to: MsgSendBool.self)
    guard let cls = NSClassFromString("LSApplicationWorkspace") else { return false }
    guard let workspace = send0(cls, NSSelectorFromString("defaultWorkspace")) else { return false }
    return sendBool(workspace, NSSelectorFromString("openApplicationWithBundleID:"), bundleID as AnyObject)
  }

  static func json(_ values: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}
