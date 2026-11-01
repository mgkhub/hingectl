import Foundation
import HingeCtlCore

/// GUI から見た、デバイスへのアクセス。実体(CoreDevice を呼ぶ)は HingeCtlApp の `LiveBackend`、テストでは偽物。
public protocol HingeBackend: Sendable {
    func listDevices() async throws -> [DeviceEntry]
    /// 切断中のデバイスの接続を張り、つながったものを、最新の状態で返す
    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry]
    func open(_ entry: DeviceEntry) async throws -> any HingeSession
}

/// 開いた 1 台のデバイス。ヒンジを使う操作は、`support()` が `.supported` のときだけ呼ぶ。
public protocol HingeSession: Sendable {
    func support() async -> HingeSupport
    func readings() async throws -> AsyncThrowingStream<[HingeReading], Error>
    func setAngle(_ degrees: Double, timeout: Double) async throws
    func sweep(from: Double, to: Double, seconds: Double, timeout: Double) async throws
    func beginSending() async throws -> any AngleSender
    func orientation() async throws -> OrientationName?
    func setOrientation(_ name: OrientationName, timeout: Double) async throws
    func rotate(_ direction: RotationDirection, timeout: Double) async throws -> OrientationName
    func posture() async throws -> PostureSnapshot
    func screenshot(to path: String) async throws -> ScreenshotOutput
}

/// スライダーのドラッグ用の連続送信。`send` は流し切らないので、最後に `flush()` を呼ぶ。
public protocol AngleSender: Sendable {
    func send(_ degrees: Double) throws
    func flush()
}
