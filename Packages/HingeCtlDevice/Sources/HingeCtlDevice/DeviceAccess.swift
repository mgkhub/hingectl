@_implementationOnly import CoreDevice
@_implementationOnly import CoreDeviceUtilities
import Foundation
import HingeCtlCore

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
/// 作った直後の `allDevices()` は空で、デバイスの登録が非同期に届く(実測で約 0.05〜0.1 秒)ため、目的の ID が現れるまで待つ。
final class RemoteDirectory {
    private var physical = RemoteDirectory.snapshotPhysical()
    private var simulators: [UUID: RemoteDevice]?
    private let simulatorIDs: Set<UUID>

    init(entries: [DeviceEntry]) {
        simulatorIDs = Set(entries.filter(\.isSimulator).compactMap { UUID(uuidString: $0.id) })
    }

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

    /// 起動中のシミュレータがすべて現れるまで待つ。上限は 5 秒。一部が現れなくても(CoreDevice が隠すシミュレータ)、
    /// 件数が 0.5 秒変わらなければ、登録が落ち着いたとみなして待ちを打ち切る。
    private func loadSimulators() async -> [UUID: RemoteDevice] {
        let manager = sharedSimulatorManager()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var lastChange = clock.now
        var lastCount = 0
        var found: [UUID: RemoteDevice] = [:]
        while clock.now < deadline {
            let all = manager.allDevices()
            found = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if simulatorIDs.isSubset(of: found.keys) { break }
            if all.count != lastCount { lastCount = all.count; lastChange = clock.now }
            if lastCount > 0 && clock.now - lastChange >= .milliseconds(500) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return found
    }
}

/// ヒンジ角に対応しているか。候補の絞り込み・表示に使う、対応の判定の入口。
/// (`openHingeStream` は、購読の失敗を `CLIError` にするため、別に確認する。)
/// 非対応(capability が無い・`supportsHingeAngle` が false)と、問い合わせの失敗(`unknown`)を区別する。
func hingeSupport(_ device: RemoteDevice) async -> HingeSupport {
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
    let chosen = try await selectDevice(from: entries, query: query, narrowByCapability: { connected in
        var foldable: [DeviceEntry] = []
        for entry in connected {
            // CoreDevice がまだ知らないデバイスは、候補にしない
            guard let remote = await directory.remote(for: entry) else { continue }
            switch await hingeSupport(remote) {
            case .supported:
                foldable.append(entry)
            case .unsupported:
                break
            case .unknown(let reason):
                // 一時的な失敗で、対応デバイスが候補から消えないよう、残す(実行時に、改めて確認される)
                HingeLog.warn("cannot determine whether \(entry.name) supports the hinge: \(reason)")
                foldable.append(entry)
            }
        }
        return foldable
    }, choose: choose, wake: { idle in
        let woken = await wakeDevices(idle)
        directory.refreshPhysical()
        return woken
    })
    guard let remote = await directory.remote(for: chosen) else {
        throw CLIError("CoreDevice does not recognize \(chosen.name)")
    }
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

/// 角度を送り、`timeout` 秒以内に CoreDevice が報告する角度が目標(±0.5°)に達するのを確認する。
/// `timeout` が 0 以下なら、確認せずに送るだけ(ただし、送信を流し切る待ちは入れる)。
func setHingeAngle(_ device: RemoteDevice, degrees: Double, timeout: Double) async throws {
    let sender = try await HingeSender(device: device)
    guard timeout > 0 else {
        try sender.send(degrees)
        try await Task.sleep(for: hidFlushDelay)
        return
    }

    // 購読を先に開いてから送る(開始直後の現在値が既に目標なら、すぐ確認できる)。
    let readings = try await openHingeReadings(device)
    try sender.send(degrees)
    let sentAt = ContinuousClock.now

    // 判定の回数(1 回目は購読開始直後の現在値)
    final class State: @unchecked Sendable { var checked = 0 }
    let state = State()

    // 判定は常に物理ヒンジ角(mechanicalAngle)を対象とする。
    // sensorAngle はパネル表面角であり、端点付近で先行して 0°/180° にスナップするため到達判定には使わない。
    // スナップ領域では CoreDevice デーモンからのストリーム通知が途絶えることがあるため、
    // ストリーム監視と定期静定確認(readHingeAngle)を並行して行い、どちらか早い方で確実に到達を検知する。
    try await withThrowingTaskGroup(of: Void.self) { group in
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
            case .found:
                if state.checked == 1 {
                    let remaining = hidFlushDelay - (ContinuousClock.now - sentAt)
                    if remaining > .zero { try await Task.sleep(for: remaining) }
                }
                return
            case .timedOut, .ended:
                throw CLIError(String(format: "The hinge angle did not reach %.1f° within %.1f seconds", degrees, timeout))
            }
        }

        // タスク 2: 端点スナップや微小変化でストリーム通知が止まった場合の定期静定確認
        group.addTask {
            let clock = ContinuousClock()
            let deadline = sentAt + .seconds(timeout)
            try await clock.sleep(for: .milliseconds(150))
            while clock.now < deadline {
                if let current = try? await readHingeAngle(device, timeout: 0.3),
                   abs(current.mechanicalAngle - degrees) <= hingeAngleTolerance {
                    return
                }
                try await clock.sleep(for: .milliseconds(150))
            }
            throw CLIError(String(format: "The hinge angle did not reach %.1f° within %.1f seconds", degrees, timeout))
        }

        // どちらか早い方が成功したら即完了し、もう一方をキャンセルする
        try await group.next()
        group.cancelAll()
    }
}

/// `from` へ移動して UI のディスプレイが切り替わった後、掃引を始めるまで待つ秒数。
/// 実機で 0 / 0.5 / 1 秒を比べ、0.5 秒に決めた(閉じた側のアニメーションが見え、待ちが長すぎない)。
let displaySettleDelay = 0.5

/// `from` から `to` まで `seconds` 秒かけて、60Hz で角度を送り続ける。
/// 各イベントは、開始時刻から数えた絶対時刻に送る(送信や起床の遅れが累積しない)。
/// イベントごとの `sendBarrier()` は往復待ちで 1 回約 17 ms かかり、毎回呼ぶと実効 26Hz 前後に落ち、
/// 指定の 2.2 倍の時間がかかった(実機で計測)。そのため、最後に 1 回だけ流し切る。
///
/// 現在角が `from` と違う場合は、掃引の前に `from` へ移動して到達を待ち、ディスプレイの切り替えが落ち着くのも待つ(ディスプレイが複数あるデバイスのみ)。
/// 待たずに掃引を始めると、`from` へ一気に飛んだ直後に掃引が始まり、`from` 側のディスプレイのアニメーションが
/// 途中で切られる。`timeout` が 0 以下なら、待たずに始める(確認しない指定と同じ扱い)。
func sweepHingeAngle(_ device: RemoteDevice, deviceID: String, from: Double, to: Double, seconds: Double, timeout: Double) async throws {
    if timeout > 0 {
        let current = try await readHingeAngle(device)
        let matches = abs(current.mechanicalAngle - from) <= hingeAngleTolerance || abs(current.sensorAngle - from) <= hingeAngleTolerance
        if !matches {
            let before = try? readDisplays(deviceID: deviceID)
            let beforeActive = before?.active.map { before!.displays[$0].uniqueId }
            try await setHingeAngle(device, degrees: from, timeout: timeout)
            if (before?.displays.count ?? 0) > 1 {
                await waitForDisplaySettle(deviceID: deviceID, before: beforeActive, settle: displaySettleDelay)
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
}

// MARK: - 向き

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

/// 現在の向き(平置きのときも、最後の平置きでない向き)。デバイスが使える向きを報告しなければ nil。
func currentOrientation(_ device: RemoteDevice) async throws -> OrientationName? {
    OrientationName(try await orientationControl(device).currentDeviceOrientation().currentDeviceNonFlatOrientation)
}

/// 向きを設定する。`timeout` 秒以内に、読み戻した向きが一致するのを確認する。
/// 反映が読み戻しに現れるまでには約 0.9 秒かかる(実機で計測)。また、送信直後にプロセスを終了すると、
/// 読み戻しの有無にかかわらず反映されなかった(待っただけでも、読み戻しを 1 回挟んでも、短いと失敗)。
/// そのため、一致するまで繰り返し読み戻して、プロセスを生かしておく。
/// `timeout` が 0 以下なら、一致を確認しても失敗にはせず、反映を待つために最大 2 秒だけ同じ読み戻しを続ける。
func setOrientation(_ device: RemoteDevice, name: OrientationName, timeout: Double) async throws {
    _ = try await orientationControl(device).changeDeviceOrientation(deviceOrientation(for: name))
    let strict = timeout > 0
    let limit: Duration = .seconds(strict ? timeout : 2.0)
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while true {
        try await Task.sleep(for: .milliseconds(200))
        if try await currentOrientation(device) == name { return }
        if clock.now >= deadline {
            if strict { throw CLIError("The orientation did not change to \(name.rawValue) within \(timeout) seconds") }
            return
        }
    }
}

/// 現在の向きから 90° 進める(順序は HingeCtlCore の `OrientationName.rotated`)。
func rotateOrientation(_ device: RemoteDevice, direction: RotationDirection, timeout: Double) async throws -> OrientationName {
    guard let current = try await currentOrientation(device) else {
        throw CLIError("Cannot interpret the current orientation: unknown")
    }
    let target = current.rotated(direction)
    try await setOrientation(device, name: target, timeout: timeout)
    return target
}
