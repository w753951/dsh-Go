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

  private func receive(_ run: Run, handle: UInt64, runID: String, kind: Int32, text: String) {
    guard active === run, run.id == runID, handle != 0, !run.terminal,
      !run.faulted || run.fault == .stopTimeout else { return }
    if run.handle == 0 { run.handle = handle } // Native callbacks may precede start's return.
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
    let hidCreate: (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
                                   UInt32, UInt32, UInt32, UInt8,
                                   Double, Double, Double, Double, UInt32, UInt32) -> Unmanaged<CFTypeRef>?)?
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
      hidCreate: look("IOHIDEventCreateDigitizerEvent",
        (@convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
                         UInt32, UInt32, UInt32, UInt8,
                         Double, Double, Double, Double, UInt32, UInt32) -> Unmanaged<CFTypeRef>?).self,
        [iokit, main]),
      hidSetFloat: look("IOHIDEventSetFloatValue", (@convention(c) (CFTypeRef, UInt32, Double) -> Void).self,
        [iokit, main]),
      hidSystemCreate: look("IOHIDEventSystemClientCreate",
        (@convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?).self, [iokit, main]),
      hidDispatch: look("IOHIDEventSystemClientDispatchEvent",
        (@convention(c) (CFTypeRef, CFTypeRef) -> Void).self, [iokit, main]))
  }()

  /// 提供给上层的实际能力。只有这里声明 true 的动作才会被允许派发。
  /// 输入（ascii/paste）依赖剪贴板 staging 与回前台流程，第一版明确不声明。
  static func capabilities() -> [String: Bool] {
    ["touch": true, "key": true, "launch": true, "apps": false]
  }

  /// 越狱权限探测：带 no-sandbox 时进程能读到越狱根目录。
  private static func processHasJailbreakPrivilege() -> Bool {
    ["/var/jb", "/var/jb/usr", "/var/jb/Library", "/private/preboot"].contains {
      FileManager.default.fileExists(atPath: $0)
    }
  }

  /// 通道是否可用。符号、权限、私有框架三者都要在。
  ///
  /// 顺序很重要：先做纯文件系统探测，没有越狱权限就直接返回，
  /// 完全不碰 `symbols`（它会 dlopen IOKit）。否则普通沙盒里的
  /// 每一次启动都会白白加载一套私有框架，只会增加风险。
  static func available() -> Bool {
    guard processHasJailbreakPrivilege() else { return false }
    let s = symbols
    guard s.screenImage != nil, s.hidCreate != nil,
          s.hidSystemCreate != nil, s.hidDispatch != nil else { return false }
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
    let index = nextFrame
    nextFrame &+= 1
    let frameID = String(index)
    lastFrameID = frameID
    lock.unlock()
    let w = Int(image.size.width * image.scale)
    let h = Int(image.size.height * image.scale)
    let meta: [String: Any] = ["outcome": "read", "kind": "screenshot",
                              "width": w, "height": h, "nativeFrameId": frameID,
                              "contentType": "image/png"]
    return Outcome(status: 0, metadata: Self.json(meta), bytes: png)
  }

  private func apps() -> Outcome {
    let payload: [String: Any] = ["apps": [[String: Any]](), "generatedAt": Date().timeIntervalSince1970]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return Outcome(status: 1, metadata: Self.json(["outcome": "notSent", "code": "ERR_PHONE_JAILBREAK_CAPTURE"]), bytes: nil)
    }
    return Outcome(status: 0, metadata: Self.json(["outcome": "read", "kind": "apps"]), bytes: data)
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
    if let raw = Self.symbols.screenImage?(), let cg = raw.takeRetainedValue() as CGImage? {
      return UIImage(cgImage: cg)
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
    withSpringBoard { handle in
      guard let raw = dlsym(handle, "SBSLaunchApplicationWithIdentifier") else { return false }
      typealias Fn = @convention(c) (CFString, Bool) -> Int32
      return unsafeBitCast(raw, to: Fn.self)(bundleID as CFString, false) == 0
    } ?? false
  }

  static func json(_ values: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}
