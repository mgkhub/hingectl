import Foundation
import HingeCtlCore
@testable import HingeCtlAppKit

/// 複数のスレッドから触られる値を、ロックで守る(ストアは、デバイスの呼び出しをメインアクターの外で実行する)。
final class Protected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    subscript<T>(_ keyPath: WritableKeyPath<Value, T>) -> T {
        get { lock.withLock { value[keyPath: keyPath] } }
        set { lock.withLock { value[keyPath: keyPath] = newValue } }
    }

    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// 呼ばれた操作を記録し、結果を差し替えられる偽のセッション。
final class FakeSession: HingeSession, @unchecked Sendable {
    private struct State {
        var supportResult: HingeSupport = .supported
        var postureResult = PostureSnapshot(mechanicalAngle: 180, sensorAngle: 180, orientation: .known(.portrait), displays: [], active: nil)
        var setAngleError: Error?
        var screenshotError: Error?
        var calls: [String] = []
        var sent: [Double] = []
        var flushCount = 0
        var continuation: AsyncThrowingStream<[HingeReading], Error>.Continuation?
    }
    private let state = Protected(State())

    var supportResult: HingeSupport { get { state[\.supportResult] } set { state[\.supportResult] = newValue } }
    var postureResult: PostureSnapshot { get { state[\.postureResult] } set { state[\.postureResult] = newValue } }
    var setAngleError: Error? { get { state[\.setAngleError] } set { state[\.setAngleError] = newValue } }
    var screenshotError: Error? { get { state[\.screenshotError] } set { state[\.screenshotError] = newValue } }
    var calls: [String] { state[\.calls] }
    var sent: [Double] { state[\.sent] }
    var flushCount: Int { state[\.flushCount] }

    func record(_ call: String) { state.mutate { $0.calls.append(call) } }

    func support() async -> HingeSupport { supportResult }

    func readings() async throws -> AsyncThrowingStream<[HingeReading], Error> {
        record("readings")
        return AsyncThrowingStream { continuation in self.state[\.continuation] = continuation }
    }

    /// 購読を終わらせる(デバイスの切断・スリープ)
    func endStream() { state[\.continuation]?.finish() }

    /// 購読をエラーで終わらせる
    func failStream(_ error: Error) { state[\.continuation]?.finish(throwing: error) }

    /// 購読に値を流す
    func emit(angle: Double) {
        state[\.continuation]?.yield([HingeReading(mechanicalAngle: angle, sensorAngle: angle, isValid: true, minAngle: 0, maxAngle: 180, timestamp: 0)])
    }

    func setAngle(_ degrees: Double, timeout: Double) async throws {
        record("setAngle \(degrees) \(timeout)")
        if let setAngleError { throw setAngleError }
    }

    func sweep(from: Double, to: Double, seconds: Double, timeout: Double) async throws {
        record("sweep \(from) \(to) \(seconds)")
    }

    func beginSending() async throws -> any AngleSender {
        record("beginSending")
        return FakeSender(session: self)
    }

    func addSent(_ degrees: Double) { state.mutate { $0.sent.append(degrees) } }
    func addFlush() { state.mutate { $0.flushCount += 1 } }

    func orientation() async throws -> OrientationName? { .portrait }

    func setOrientation(_ name: OrientationName, timeout: Double) async throws { record("orient \(name.rawValue)") }

    func rotate(_ direction: RotationDirection, timeout: Double) async throws -> OrientationName {
        record("rotate")
        return .landscapeLeft
    }

    func posture() async throws -> PostureSnapshot {
        record("posture")
        return postureResult
    }

    /// 本物と同じく、ファイルを書く(失敗する場合も、書きかけのファイルを残す)
    func screenshot(to path: String) async throws -> ScreenshotOutput {
        record("screenshot")
        FileManager.default.createFile(atPath: path, contents: Data("png".utf8))
        if let screenshotError { throw screenshotError }
        return ScreenshotOutput(display: "LCD", path: path)
    }
}

struct FakeSender: AngleSender {
    let session: FakeSession
    func send(_ degrees: Double) throws { session.addSent(degrees) }
    func flush() { session.addFlush() }
}

final class FakeBackend: HingeBackend, @unchecked Sendable {
    private struct State {
        var devices: [DeviceEntry]
        var listError: Error?
        var wakeResult: [DeviceEntry]?
        var wakeCalls = 0
        var openedIDs: [String] = []
    }
    private let state: Protected<State>
    let session = FakeSession()

    var devices: [DeviceEntry] { get { state[\.devices] } set { state[\.devices] = newValue } }
    var listError: Error? { get { state[\.listError] } set { state[\.listError] = newValue } }
    var wakeResult: [DeviceEntry]? { get { state[\.wakeResult] } set { state[\.wakeResult] = newValue } }
    var wakeCalls: Int { state[\.wakeCalls] }
    var openedIDs: [String] { state[\.openedIDs] }

    init(devices: [DeviceEntry]) { state = Protected(State(devices: devices)) }

    func listDevices() async throws -> [DeviceEntry] {
        if let listError { throw listError }
        return devices
    }

    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry] {
        state.mutate { $0.wakeCalls += 1 }
        return wakeResult ?? []
    }

    func open(_ entry: DeviceEntry) async throws -> any HingeSession {
        state.mutate { $0.openedIDs.append(entry.id) }
        return session
    }
}

func entry(_ name: String, state: ConnectionState = .connected, transport: String? = "wired") -> DeviceEntry {
    DeviceEntry(id: "id-\(name)", name: name, udid: "udid-\(name)", connectionState: state, transport: transport)
}

/// 条件が満たされるまで、メインアクターを譲りながら待つ(上限 2 秒)。
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// open が、合図があるまで終わらないバックエンド(A だけ)
final class SlowBackend: HingeBackend, @unchecked Sendable {
    let devices = [entry("A"), entry("B")]
    let sessionA = FakeSession()
    let sessionB = FakeSession()
    private let gate = Protected<CheckedContinuation<Void, Never>?>(nil)

    func release() {
        gate.mutate { continuation in
            continuation?.resume()
            continuation = nil
        }
    }

    func listDevices() async throws -> [DeviceEntry] { devices }
    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry] { entries }

    func open(_ entry: DeviceEntry) async throws -> any HingeSession {
        if entry.name == "A" {
            await withCheckedContinuation { continuation in gate.mutate { $0 = continuation } }
            return sessionA
        }
        return sessionB
    }
}
