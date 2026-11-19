@_implementationOnly import CoreDevice
@_implementationOnly import CoreDeviceProtocols
@_implementationOnly import CoreDeviceUtilities
import Foundation
import HingeCtlCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - デバイスの選択

/// シミュレータも許可した `DeviceManager`。作るたびに約 0.58 MB 増えて戻らない(シミュレータを 60 回開いて計測)ため、
/// プロセスで 1 つだけ作って使い回す。引いた RemoteDevice は、`RemoteDirectory` より長く使われるので、手放さない
/// (手放しても動くことは実測したが、保証は無い)。GUI は、選ぶたびに開き直す。
private let simulatorManagerLock = NSLock()
private var simulatorManager: DeviceManager?

private func sharedSimulatorManager() -> DeviceManager {
    simulatorManagerLock.lock()
    defer { simulatorManagerLock.unlock() }
    if let simulatorManager { return simulatorManager }
    let manager = DeviceManager(serviceConnection: CoreDeviceService.sharedConnection,
                                allowedDeviceVisibilityClasses: [.default, .simulators])
    simulatorManager = manager
    return manager
}

/// 実機は、`DeviceManager.shared` から引く。シミュレータ(visibilityClass が simulators)は、既定の
/// `shared` が許可していないため、シミュレータも許可した `DeviceManager` を、必要になったときだけ作って引く。
/// 作った直後の `allDevices()` は空で、デバイスの登録が非同期に届くため、初期チェックイン完了を待つ。
final class RemoteDirectory {
    private var physical = RemoteDirectory.snapshotPhysical()
    private var simulators: [UUID: RemoteDevice]?

    init(entries: [DeviceEntry]) {}

    private static func snapshotPhysical() -> [UUID: RemoteDevice] {
        Dictionary(DeviceManager.shared.allDevices().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 切断中のデバイスを起こしたあと、最新の状態で引くために取り直す
    func refreshPhysical() { physical = RemoteDirectory.snapshotPhysical() }

    func remote(for entry: DeviceEntry) async -> RemoteDevice? {
        guard let uuid = UUID(uuidString: entry.id) else { return nil }
        guard entry.isSimulator else { return physical[uuid] }
        if simulators == nil { simulators = await loadSimulators() }
        return simulators?[uuid]
    }

    /// シミュレータ用 `DeviceManager` の初期チェックイン完了を待ってから全デバイスを辞書化する。
    private func loadSimulators() async -> [UUID: RemoteDevice] {
        let manager = sharedSimulatorManager()
        if !manager.fullyInitialized {
            await manager.awaitFullInitialization()
        }
        return Dictionary(manager.allDevices().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// ヒンジ角に対応しているか。候補の絞り込み・表示に使う、対応の判定の入口。
/// (`openHingeStream` は、購読の失敗を `CLIError` にするため、別に確認する。)
/// 非対応(capability が無い・`supportsHingeAngle` が false)と、問い合わせの失敗(`unknown`)を区別する。
/// 失敗(`unknown`)は、接続の直後などの一時的なものがあるので、短い間隔で数回やり直す。
func hingeSupport(_ device: RemoteDevice, attempts: Int = 3, interval: Duration = .milliseconds(500)) async -> HingeSupport {
    var support = await queryHingeSupport(device)
    var remaining = attempts - 1
    while case .unknown = support, remaining > 0 {
        do {
            try await Task.sleep(for: interval)
        } catch {
            break
        }
        support = await queryHingeSupport(device)
        remaining -= 1
    }
    return support
}

private func queryHingeSupport(_ device: RemoteDevice) async -> HingeSupport {
    do {
        let supported = try await device.getImplementation(for: .monitorMotion).motionManager().supportsHingeAngle
        return supported ? .supported : .unsupported
    } catch {
        let nsError = error as NSError
        return classifyHingeError(domain: nsError.domain, code: nsError.code, reason: nsError.localizedDescription)
    }
}

/// ヒンジを使う操作の前に呼ぶ。ヒンジに対応していないデバイスには、何も送らずにエラーにする。
/// 対応かどうか分からない(問い合わせの失敗)ときも、何も送らずにエラーにする(原因を添える)。
func requireHinge(_ device: RemoteDevice, name: String) async throws {
    switch await hingeSupport(device) {
    case .supported:
        return
    case .unsupported:
        throw CLIError("\(name) does not support the hinge")
    case .unknown(let reason):
        throw CLIError("\(name): cannot determine whether it supports the hinge: \(reason)")
    }
}

/// `query` からデバイスを 1 台に絞り、CoreDevice の RemoteDevice を得る(選択の規則は HingeCtlCore の `selectDevice`)。
/// `choose` は、ヒンジ対応のデバイスが複数あるときの選択(nil なら、エラーにする)。
func resolveRemoteDevice(_ query: String?, choose: (([DeviceEntry]) async throws -> DeviceEntry)?) async throws -> (RemoteDevice, DeviceEntry) {
    let entries = try listDevices()
    let directory = RemoteDirectory(entries: entries)
    // 利用者が選んだのか(対話)、1 台に絞れて自動で決まったのか、を区別する
    var askedUser = false
    let chosenByUser: (([DeviceEntry]) async throws -> DeviceEntry)? = choose.map { choose in
        { candidates in
            askedUser = true
            return try await choose(candidates)
        }
    }
    var undetermined: [DeviceEntry] = []
    let chosen = try await selectDevice(from: entries, query: query, narrowByCapability: { connected in
        // CoreDevice の RemoteDevice を解決(既知のデバイスのみ候補にする)
        var remotes: [(entry: DeviceEntry, remote: RemoteDevice)] = []
        for entry in connected {
            if let remote = await directory.remote(for: entry) {
                remotes.append((entry, remote))
            }
        }
        guard !remotes.isEmpty else { return [] }

        // 不明(unknown)な端末が複数台あっても待ち時間が累積しないよう、ヒンジ対応の判定を並行して行う。
        // リストの順序を保つため、元のインデックスを保持してソートする。
        typealias CheckResult = (index: Int, entry: DeviceEntry, support: HingeSupport)
        let results = await withTaskGroup(of: CheckResult.self) { group in
            for (index, pair) in remotes.enumerated() {
                group.addTask {
                    let support = await hingeSupport(pair.remote)
                    return (index, pair.entry, support)
                }
            }
            var collected: [CheckResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.index < $1.index }
        }

        var foldable: [DeviceEntry] = []
        for result in results {
            switch result.support {
            case .supported:
                foldable.append(result.entry)
            case .unsupported:
                break
            case .unknown(let reason):
                // やり直しても分からないデバイスは、誤って選ばないよう、候補から外す(`-d` で指定すれば、実行時に改めて確認される)
                HingeLog.warn("cannot determine whether \(result.entry.name) supports the hinge, so it is not a candidate: \(reason)")
                if !undetermined.contains(where: { $0.id == result.entry.id }) { undetermined.append(result.entry) }
            }
        }
        return foldable
    }, choose: chosenByUser, wake: { idle in
        let woken = await wakeDevices(idle)
        directory.refreshPhysical()
        return woken
    }, undetermined: { undetermined })
    guard let remote = await directory.remote(for: chosen) else {
        throw CLIError("CoreDevice does not recognize \(chosen.name)")
    }
    // `-d` も `$HINGECTL_DEVICE` も無く、聞かれもせずに決まったときは、どのデバイスかを知らせる
    if query == nil && !askedUser { HingeLog.note(implicitSelectionNote(chosen)) }
    return (remote, chosen)
}

// MARK: - ヒンジ角の読み取り

/// ヒンジ角の誤差の許容(度)。購読の変化の閾値、設定後の到達の確認、`sweep` の事前移動の要否の判定で共通に使う。
let hingeAngleTolerance = 0.5

extension HingeReading {
    init(_ s: DeviceHingeAngleSnapshot) {
        let mech = s.mechanicalAngle.converted(to: .degrees).value
        let sensor = s.angle.converted(to: .degrees).value
        self.init(mechanicalAngle: mech,
                  sensorAngle: sensor,
                  isValid: s.isAngleValid,
                  minAngle: s.minAngle.converted(to: .degrees).value,
                  maxAngle: s.maxAngle.converted(to: .degrees).value,
                  timestamp: s.timestamp)
    }
}

/// ヒンジ角の購読を開始する。購読開始直後に現在値が 1 件届く。
func openHingeStream(_ device: RemoteDevice) async throws -> AsyncThrowingStream<[DeviceHingeAngleSnapshot], Error> {
    let motion: DeviceMotionManager
    do {
        motion = try await device.getImplementation(for: .monitorMotion).motionManager()
    } catch {
        throw CLIError("This device does not support motion monitoring: \(error)")
    }
    guard motion.supportsHingeAngle else {
        throw CLIError("This device does not support reading the hinge angle")
    }
    let config = HingeAngleStreamConfig(changeThreshold: Measurement(value: hingeAngleTolerance, unit: .degrees), updateInterval: .milliseconds(200))
    do {
        return try await motion.monitorHingeAngle(config: config)
    } catch {
        throw CLIError("Failed to subscribe to the hinge angle: \(error)")
    }
}

/// `openHingeStream` を `HingeReading` に変換した列。
func openHingeReadings(_ device: RemoteDevice) async throws -> some AsyncSequence<[HingeReading], Error> {
    try await openHingeStream(device).map { $0.map(HingeReading.init) }
}

/// ヒンジ角の列のエラーを、原因つきの `CLIError` にする(取り消しは、そのまま)。
func hingeStreamFailure(_ error: Error) -> Error {
    if error is CLIError || error is CancellationError { return error }
    return CLIError("The hinge angle stream failed: \((error as NSError).localizedDescription)")
}

/// 現在のヒンジ角を 1 件読む。購読開始直後に現在値が届くので、通常は即座に返る。
/// 届かないときのために、`timeout` 秒で打ち切る。
/// 列のエラー(切断など)は、時間切れにせず、原因を示して失敗する。
func readHingeAngle(_ device: RemoteDevice, timeout: Double = 2) async throws -> HingeReading {
    let readings = try await openHingeReadings(device)
    let result: FirstElement<[HingeReading]>
    do {
        result = try await firstElement(of: readings, timeout: .seconds(timeout)) { !$0.isEmpty }
    } catch {
        throw hingeStreamFailure(error)
    }
    switch result {
    case .found(let batch): return batch[0]
    case .timedOut: throw CLIError("Could not read the hinge angle (no value within \(timeout) seconds)")
    case .ended: throw CLIError("The hinge angle stream ended before a value arrived")
    }
}

// MARK: - ヒンジ角の設定

/// IOKit の IOCFSerialize(バイナリ形式)。非公開関数のため dlsym で解決する(1 度だけ解決して使い回す)。
private typealias SerializeFn = @convention(c) (CFTypeRef, CFOptionFlags) -> Unmanaged<CFData>?
private let kSerializeBinary: CFOptionFlags = 1

private let cachedIOCFSerialize: SerializeFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
    guard let symbol = dlsym(handle, "IOCFSerialize") else { return nil }
    return unsafeBitCast(symbol, to: SerializeFn.self)
}()

private func getIOCFSerialize() throws -> SerializeFn {
    guard let fn = cachedIOCFSerialize else { throw CLIError("Cannot resolve IOCFSerialize") }
    return fn
}

/// Device Hub のヒンジスライダーと同じ vendor-defined HID イベントでヒンジ角を送る。
/// ペイロードはシミュレータと同形式の辞書。
/// シリアライザと HID の取得は 1 回だけ行い、`sweep` の連続送信で使い回す。
struct HingeSender {
    private let serialize: SerializeFn
    // CoreDevice の型を、保存プロパティの型にしない(HingeDevice の `handle` と同じ理由)
    private let hidHandle: Any
    private var hid: any HIDVendorDefined { hidHandle as! any HIDVendorDefined }

    init(device: RemoteDevice) async throws {
        serialize = try getIOCFSerialize()
        do {
            hidHandle = try await device.getImplementation(for: .hid.vendorDefined) as any HIDVendorDefined
        } catch {
            throw CLIError("This device does not support vendor-defined HID: \(error)")
        }
    }

    /// 角度(0〜180 度)を送る。範囲の検証は呼び出し側で行う。
    /// `barrier` が true なら、送信を流し切る `sendBarrier()` まで行う。`sendBarrier()` は往復を待つため
    /// 1 回に約 17 ms かかり(実機で計測)、連続送信では毎回呼ばず、最後に `flush()` で 1 回だけ呼ぶ。
    func send(_ degrees: Double, barrier: Bool = true) throws {
        let payload: [String: Any] = [
            "provider": "com.apple.Virtualization.VirtualMachines",
            "source": "hinge-slider-control",
            "type": "range",
            "value": degrees,
        ]
        guard let data = serialize(payload as CFDictionary, kSerializeBinary)?.takeRetainedValue() else {
            throw CLIError("Failed to serialize the payload")
        }
        do {
            try hid.send(usagePage: 0xFF61, usage: 0x5B, version: 0, data: data as Data)
        } catch {
            throw CLIError("Failed to send the HID event: \(error)")
        }
        if barrier { hid.sendBarrier() }
    }

    func flush() { hid.sendBarrier() }
}

/// 送信直後にプロセスを終了すると、イベントがデバイスに届く前に切れて反映されない(実機で確認)。
/// そのため、確認しない場合でも、送信後にこの時間だけ待ってから終了する。
let hidFlushDelay = Duration.milliseconds(300)

/// 送信開始時刻からの経過時間を考慮し、hidFlushDelay (300ms) の残余時間だけスリープする。
func sleepRemainingHidFlush(since sentAt: ContinuousClock.Instant, total: Duration = hidFlushDelay) async throws {
    let elapsed = ContinuousClock.now - sentAt
    if total > elapsed {
        try await Task.sleep(for: total - elapsed)
    }
}

/// タイムアウト時の CLIError を一貫したトーン＆マナーで生成する。
func makeTimeoutError(item: String, target: String, timeout: Double, reason: String? = nil) -> CLIError {
    let base = "The \(item) did not \(target) within \(String(format: "%.1f", timeout)) seconds"
    if let reason {
        return CLIError("\(base) (\(reason); pass -t 0 to send without waiting)")
    } else {
        return CLIError("\(base) (pass -t 0 to send without waiting)")
    }
}

/// 読み戻し値が目標と乖離している場合の警告を出力する。
func warnMismatch(actual: String, target: String, item: String, context: String) {
    HingeLog.warn("the \(item) read back is \(actual), not \(target) (\(context))")
}

/// 角度を送り、`timeout` 秒以内に CoreDevice が報告する角度が目標(±0.5°)に達するのを確認する。
/// `timeout` が 0 以下なら、確認せずに送るだけ(ただし、送信を流し切る待ちは入れる)。
/// 戻り値は、完了後に読み戻した角度(読めなければ nil)。
@discardableResult
func setHingeAngle(_ device: RemoteDevice, degrees: Double, timeout: Double) async throws -> Double? {
    let sender = try await HingeSender(device: device)
    let sentAt = ContinuousClock.now

    guard timeout > 0 else {
        try sender.send(degrees)
        try await sleepRemainingHidFlush(since: sentAt)
        if let actual = try? await readHingeAngle(device, timeout: 0.5) {
            let angle = actual.mechanicalAngle
            if abs(angle - degrees) > hingeAngleTolerance {
                warnMismatch(actual: angleText(angle), target: angleText(degrees), item: "angle", context: "not applied yet, or changed concurrently")
            }
            return angle
        } else {
            HingeLog.warn("could not read back the current angle (not applied yet, or changed concurrently)")
            return nil
        }
    }

    // 購読を先に開いてから送る(開始直後の現在値が既に目標なら、すぐ確認できる)。
    let readings = try await openHingeReadings(device)
    try sender.send(degrees)

    // 判定の回数(1 回目は購読開始直後の現在値)
    final class State: @unchecked Sendable { var checked = 0 }
    let state = State()

    let deadline = sentAt + .seconds(timeout)

    // 判定は常に物理ヒンジ角(mechanicalAngle)を対象とする。
    // sensorAngle はパネル表面角であり、端点付近で先行して 0°/180° にスナップするため到達判定には使わない。
    // スナップ領域では CoreDevice デーモンからのストリーム通知が途絶えることがあるため、
    // ストリーム監視と定期静定確認(readHingeAngle)を並行して行い、どちらか早い方で確実に到達を検知する。
    return try await withThrowingTaskGroup(of: Double?.self) { group in
        // タスク 1: ストリームからの変化イベント監視
        group.addTask {
            let result: FirstElement<[HingeReading]>
            do {
                result = try await firstElement(of: readings, timeout: .seconds(timeout)) { batch in
                    state.checked += 1
                    return batch.contains { abs($0.mechanicalAngle - degrees) <= hingeAngleTolerance }
                }
            } catch {
                throw hingeStreamFailure(error)
            }
            switch result {
            case .found(let batch):
                let reached = batch.last(where: { abs($0.mechanicalAngle - degrees) <= hingeAngleTolerance })?.mechanicalAngle ?? degrees
                if state.checked == 1 {
                    try await sleepRemainingHidFlush(since: sentAt)
                }
                return reached
            case .timedOut:
                throw makeTimeoutError(item: "hinge angle", target: "reach \(angleText(degrees))°", timeout: timeout)
            case .ended:
                // ストリームが先に終了しても、定期静定確認(タスク 2)の判定を待つ
                return nil
            }
        }

        // タスク 2: 端点スナップや微小変化でストリーム通知が止まった場合の定期静定確認
        group.addTask {
            let clock = ContinuousClock()
            try await clock.sleep(for: .milliseconds(150))
            while clock.now < deadline {
                if let current = try? await readHingeAngle(device, timeout: 0.3),
                   abs(current.mechanicalAngle - degrees) <= hingeAngleTolerance {
                    try await sleepRemainingHidFlush(since: sentAt)
                    return current.mechanicalAngle
                }
                try await clock.sleep(for: .milliseconds(150))
            }
            return nil
        }

        // どちらか早い方が到達を検知したら即完了し、もう一方をキャンセルする
        for try await angle in group {
            if let angle {
                group.cancelAll()
                return angle
            }
        }
        throw makeTimeoutError(item: "hinge angle", target: "reach \(angleText(degrees))°", timeout: timeout)
    }
}

/// `from` へ移動して UI のディスプレイが切り替わった後、掃引を始めるまで待つ秒数。
/// 実機で 0 / 0.5 / 1 秒を比べ、0.5 秒に決めた(閉じた側のアニメーションが見え、待ちが長すぎない)。
let displaySettleDelay = 0.5

/// 折りたたみ・展開のあと、UI を載せるディスプレイの切り替えを待つ。
/// `before` は、移動前に UI を載せていたディスプレイの uniqueId。
func waitForDisplaySettle(_ device: RemoteDevice, before: String?, settle: Double, maxSeconds: Double = 6) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(maxSeconds)
    let initialLimit = clock.now + .seconds(1)
    var switchedAt: ContinuousClock.Instant?
    let settleDuration = Duration.seconds(settle)
    while clock.now < deadline {
        guard let state = try? await readDisplaysInProcess(device) else {
            HingeLog.warn("cannot read the display state; continuing without waiting for the switch")
            return
        }
        let display = state.active.map { state.displays[$0] }
        let lit = display?.isLit ?? false
        if display?.uniqueId != before && lit && switchedAt == nil { switchedAt = clock.now }
        if let switchedAt {
            if clock.now - switchedAt >= settleDuration { return }
        } else if clock.now >= initialLimit {
            return
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// `from` から `to` まで `seconds` 秒かけて、60Hz で角度を送り続ける。
/// 各イベントは、開始時刻から数えた絶対時刻に送る(送信や起床の遅れが累積しない)。
/// イベントごとの `sendBarrier()` は往復待ちで 1 回約 17 ms かかり、毎回呼ぶと実効 26Hz 前後に落ち、
/// 指定の 2.2 倍の時間がかかった(実機で計測)。そのため、最後に 1 回だけ流し切る。
///
/// 現在角が `from` と違う場合は、掃引の前に `from` へ移動して到達を待ち、ディスプレイの切り替えが落ち着くのも待つ(ディスプレイが複数あるデバイスのみ)。
/// 待たずに掃引を始めると、`from` へ一気に飛んだ直後に掃引が始まり、`from` 側のディスプレイのアニメーションが
/// 途中で切られる。`timeout` が 0 以下なら、待たずに始める(確認しない指定と同じ扱い)。
@discardableResult
func sweepHingeAngle(_ device: RemoteDevice, from: Double, to: Double, seconds: Double, timeout: Double) async throws -> Double? {
    if timeout > 0 {
        let current = try await readHingeAngle(device)
        let matches = abs(current.mechanicalAngle - from) <= hingeAngleTolerance || abs(current.sensorAngle - from) <= hingeAngleTolerance
        if !matches {
            let before = try? await readDisplaysInProcess(device)
            let beforeActive = before?.active.map { before!.displays[$0].uniqueId }
            try await setHingeAngle(device, degrees: from, timeout: timeout)
            if (before?.displays.count ?? 0) > 1 {
                await waitForDisplaySettle(device, before: beforeActive, settle: displaySettleDelay)
            }
        }
    }

    let sender = try await HingeSender(device: device)
    let plan = SweepPlan(from: from, to: to, seconds: seconds)
    let clock = ContinuousClock()
    let start = clock.now
    for i in 0...plan.steps {
        try sender.send(plan.angle(at: i), barrier: false)
        if i < plan.steps {
            try await clock.sleep(until: start + .seconds(plan.time(at: i + 1)))
        }
    }
    sender.flush()
    try await Task.sleep(for: hidFlushDelay)

    // 掃引完了後の角度をデバイスから読み戻す
    if let current = try? await readHingeAngle(device, timeout: timeout > 0 ? min(timeout, 1.0) : 0.5) {
        let actual = current.mechanicalAngle
        if abs(actual - to) > hingeAngleTolerance {
            warnMismatch(actual: angleText(actual), target: angleText(to), item: "angle", context: "not applied yet, or changed concurrently")
        }
        return actual
    } else {
        HingeLog.warn("could not read back the current angle (not applied yet, or changed concurrently)")
        return nil
    }
}

// MARK: - 向き

private let lastOrientationsLock = NSLock()
private var lastOrientations: [UUID: OrientationName] = [:]

func getLastKnownOrientation(for id: UUID) -> OrientationName? {
    lastOrientationsLock.lock()
    defer { lastOrientationsLock.unlock() }
    return lastOrientations[id]
}

func setLastKnownOrientation(_ name: OrientationName, for id: UUID) {
    lastOrientationsLock.lock()
    defer { lastOrientationsLock.unlock() }
    lastOrientations[id] = name
}

func deviceOrientation(for name: OrientationName) -> DeviceOrientation {
    switch name {
    case .portrait: return .portrait
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .portraitUpsideDown: return .portraitUpsideDown
    }
}

func orientationControl(_ device: RemoteDevice) async throws -> any OrientationControl {
    do {
        return try await device.getImplementation(for: .orientationControl)
    } catch {
        throw CLIError("This device does not support orientation control: \(error)")
    }
}

extension OrientationName {
    /// CoreDevice の向きを、設定・表示できる向きにする。平置き・不明は nil。
    init?(_ orientation: DeviceOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .faceUp, .faceDown, .unknown: return nil
        @unknown default: return nil
        }
    }
}

/// 現在の向き(端末の論理向き)。
/// 物理センサーが有効な非平置き姿勢(portrait, landscape 等)を報告していればそれを採用し、
/// 机の上などの平置き状態(faceUp / faceDown)のときは現在アクティブなディスプレイの描画回転(rotation)から逆算して返す。
/// 画面の回転が制限されている場合や取得できない場合は、直前の非平置き向きや直近に設定された論理向き(初回は portrait)を返す。
func currentOrientation(_ device: RemoteDevice) async throws -> OrientationName? {
    let ctrl = try await orientationControl(device)
    let info = try await ctrl.currentDeviceOrientation()
    // 1. 現在の物理向き(手で持って立てた・回転させた場合はここに portrait/landscape が入る)を最優先
    if let direct = OrientationName(info.currentDeviceOrientation) {
        setLastKnownOrientation(direct, for: device.id)
        return direct
    }
    // 2. 平置き(faceUp/faceDown)のときは、アクティブなディスプレイの rotation から逆算
    if let state = try? await readDisplaysInProcess(device),
       let inferred = inferOrientation(displays: state.displays, active: state.active) {
        setLastKnownOrientation(inferred, for: device.id)
        return inferred
    }
    // 3. ディスプレイから逆算できない場合(ホーム画面固定・消灯等)は直前の非平置き向きを採用
    if let nonFlat = OrientationName(info.currentDeviceNonFlatOrientation) {
        setLastKnownOrientation(nonFlat, for: device.id)
        return nonFlat
    }
    // 4. それもなければキャッシュされた直近の論理向きを採用
    if let cached = getLastKnownOrientation(for: device.id) {
        return cached
    }
    return .portrait
}

/// 向きを設定する。
/// `changeDeviceOrientation` は OS のウィンドウマネージャにシミュレートされたデバイス向きイベントを送信する。
/// 反映が読み戻しやディスプレイ描画に現れるまでには約 0.4〜0.9 秒かかるため、
/// `timeout` 秒以内に目標の向きが反映されたことを確認して完了する。
/// `timeout` が 0 以下なら、確認せずに流し切り待機(`hidFlushDelay`)だけ置いて終了する。
@discardableResult
func setOrientation(_ device: RemoteDevice, name: OrientationName, timeout: Double) async throws -> OrientationName? {
    let ctrl = try await orientationControl(device)
    let sentAt = ContinuousClock.now
    _ = try await ctrl.changeDeviceOrientation(deviceOrientation(for: name))
    setLastKnownOrientation(name, for: device.id)

    guard timeout > 0 else {
        try await sleepRemainingHidFlush(since: sentAt)
        let actual = try? await currentOrientation(device)
        if actual != name {
            warnMismatch(actual: orientationText(actual), target: name.rawValue, item: "orientation", context: "not applied yet, or the device does not allow it")
        }
        return actual
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeout)
    // timeout に応じて間隔を調整(最小 20ms、最大 100ms)
    let pollInterval = max(Duration.milliseconds(20), min(Duration.milliseconds(100), .seconds(timeout / 4)))

    while true {
        let latest = try? await currentOrientation(device)
        if latest == name {
            try await sleepRemainingHidFlush(since: sentAt)
            return latest
        }
        let now = clock.now
        if now >= deadline {
            throw makeTimeoutError(item: "orientation", target: "change to \(name.rawValue)", timeout: timeout, reason: "the device or app may not allow this orientation")
        }
        let remaining = deadline - now
        try await Task.sleep(for: min(pollInterval, remaining))
    }
}

/// 現在の向きから 90° 進める(順序は HingeCtlCore の `OrientationName.rotated`)。
/// 戻り値は、実行後に読み戻した向き。
func rotateOrientation(_ device: RemoteDevice, direction: RotationDirection, timeout: Double) async throws -> OrientationName {
    guard let current = try await currentOrientation(device) else {
        throw CLIError("Cannot interpret the current orientation: unknown")
    }
    let target = current.rotated(direction)
    return try await setOrientation(device, name: target, timeout: timeout) ?? current
}

// MARK: - ディスプレイ情報(プロセス内)

/// プロセス内の CoreDevice(`RemoteDevice.displayInfo`)から、ディスプレイ情報を読む。
func readDisplaysInProcess(_ device: RemoteDevice) async throws -> (displays: [DisplayState], active: Int?) {
    let info = try await device.displayInfo
    let encoded = try JSONEncoder().encode(info)
    return try decodeDisplays(data: encoded)
}

// MARK: - スクリーンショット(プロセス内)

private func captureScreenshotControl(_ device: RemoteDevice) async throws -> any CaptureScreenshotProtocol {
    do {
        return try await device.getImplementation(for: .captureScreenshot)
    } catch {
        throw CLIError("This device does not support screenshot capture: \(error)")
    }
}

/// プロセス内の CoreDevice(`CaptureScreenshotCapability`)からスクリーンショットを取得し、PNG ファイルとして保存する。
func takeScreenshotInProcess(_ device: RemoteDevice, displayUniqueID: String?, to destinationPath: String) async throws {
    let control = try await captureScreenshotControl(device)
    let output: CaptureScreenshotOutput
    do {
        output = try await control.captureScreenshot(displayUniqueID: displayUniqueID, format: .png)
    } catch {
        throw CLIError("Failed to take screenshot: \(error)")
    }

    let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
    do {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        throw CLIError("Cannot create destination directory for \(destinationURL.path): \(error.localizedDescription)")
    }

    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CLIError("Cannot create image destination for \(destinationURL.path)")
    }
    CGImageDestinationAddImage(destination, output.image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError("Cannot write screenshot to \(destinationURL.path)")
    }
}

// MARK: - デバイス一覧(プロセス内)

private let simulatorWarmupLock = NSLock()
private var simulatorWarmedUp = false

private func warmedUpSimulatorDevices() -> [RemoteDevice] {
    let manager = sharedSimulatorManager()
    simulatorWarmupLock.lock()
    defer { simulatorWarmupLock.unlock() }
    if simulatorWarmedUp || manager.fullyInitialized {
        simulatorWarmedUp = true
        return manager.allDevices()
    }

    // CoreDevice の初期チェックイン完了通知をイベント駆動で待つ(既に完了済みでもハンドラは即呼ばれる)。
    // 応答が無い異常系への安全弁として上限 5 秒のタイムアウトを置く。
    let semaphore = DispatchSemaphore(value: 0)
    manager.addFullyInitializedHandler(on: nil) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(5))

    simulatorWarmedUp = true
    return manager.allDevices()
}

func listDevicesInProcess() throws -> [DeviceEntry] {
    let physical = DeviceManager.shared.allDevices()
    let simulators = warmedUpSimulatorDevices()

    // 重複を排除しつつ実機を先、シミュレータを後に並べる
    var seen = Set<UUID>()
    var physicalRemotes: [RemoteDevice] = []
    var simRemotes: [RemoteDevice] = []
    for d in physical {
        if seen.insert(d.id).inserted { physicalRemotes.append(d) }
    }
    for d in simulators {
        if seen.insert(d.id).inserted { simRemotes.append(d) }
    }

    func parseEntry(from remote: RemoteDevice) -> DeviceEntry? {
        guard let encoded = try? JSONEncoder().encode(remote.deviceInfo) else { return nil }
        var capabilities: Set<String> = []
        if remote.supportsFeature(identifiedBy: DeviceEntry.orientationControlFeature) || remote.supports(.orientationControl) {
            capabilities.insert(DeviceEntry.orientationControlFeature)
        }
        return decodeCoreDeviceRecord(data: encoded, capabilities: capabilities)
    }

    var entries: [DeviceEntry] = []
    for remote in physicalRemotes {
        if let entry = parseEntry(from: remote) {
            entries.append(entry)
        }
    }
    for remote in simRemotes {
        if let entry = parseEntry(from: remote) {
            entries.append(entry)
        }
    }
    return entries
}

// MARK: - 切断デバイスの接続確立(プロセス内)

private final class ConnectAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        return true
    }
}

/// 接続試行をタイムアウト付きで実行する。
/// `remote.connect()` が Swift Concurrency の協調的キャンセルに応答しない場合でも、
/// `withCheckedThrowingContinuation` を用いることでタイムアウト時に呼び出し元へ確実に即時復帰する。
private func connectWithTimeout(_ remote: RemoteDevice, timeout: Duration = .seconds(10)) async throws {
    let state = ConnectAttemptState()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let connectTask = Task {
            do {
                try await remote.connect()
                if state.claim() {
                    continuation.resume()
                }
            } catch {
                if state.claim() {
                    continuation.resume(throwing: error)
                }
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if state.claim() {
                connectTask.cancel()
                try? await remote.disconnect()
                continuation.resume(throwing: CLIError("connection timed out"))
            }
        }
    }
}

/// 切断中(トンネルがアイドル)のデバイスの接続をプロセス内で張り、つながったものを最新の状態で返す。
func wakeDevicesInProcess(_ entries: [DeviceEntry]) async -> [DeviceEntry] {
    guard !entries.isEmpty else { return [] }
    HingeLog.note("connecting to \(entries.map(\.name).joined(separator: ", "))...")

    var allRemotes = DeviceManager.shared.allDevices()
    allRemotes.append(contentsOf: sharedSimulatorManager().allDevices())
    let remotesByID = Dictionary(allRemotes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

    let failures = await withTaskGroup(of: (id: String, reason: String).self) { group in
        for entry in entries {
            guard let remote = remotesByID[entry.id] else {
                group.addTask { (entry.id, "device not found in CoreDevice") }
                continue
            }
            group.addTask {
                do {
                    try await connectWithTimeout(remote, timeout: .seconds(10))
                    return (entry.id, "")
                } catch {
                    // タイムアウトまたは失敗時、放置された接続セッションを確実にクリーンアップ
                    try? await remote.disconnect()
                    return (entry.id, "\(error)")
                }
            }
        }
        var reasons: [String: String] = [:]
        for await result in group { reasons[result.id] = result.reason }
        return reasons
    }

    let refreshed: [DeviceEntry]
    do {
        refreshed = try listDevicesInProcess()
    } catch {
        HingeLog.warn("cannot read the device list after connecting: \(error)")
        return []
    }

    var connected: [DeviceEntry] = []
    for entry in entries {
        if let now = refreshed.first(where: { $0.id == entry.id }), now.isConnected {
            connected.append(now)
        } else {
            let reason = failures[entry.id].flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            HingeLog.warn("could not connect to \(entry.name)\(reason)")
        }
    }
    return connected
}
