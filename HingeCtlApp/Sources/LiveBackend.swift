import Foundation
import HingeCtlAppKit
import HingeCtlCore
import HingeCtlDevice

/// 実際のバックエンド。CoreDevice を呼ぶのは HingeCtlDevice で、ここは `HingeBackend` の型に合わせるだけ。
/// 呼び出しはメインアクターの外で実行される(devicectl の待ちで、画面を止めないため)。
struct LiveBackend: HingeBackend {
    func listDevices() async throws -> [DeviceEntry] { try HingeCtlDevice.listDevices() }

    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry] { await wakeDevices(entries) }

    func open(_ entry: DeviceEntry) async throws -> any HingeSession {
        LiveSession(device: try await HingeDevice.open(entry))
    }
}

struct LiveSession: HingeSession {
    let device: HingeDevice

    func support() async -> HingeSupport { await device.support() }
    func readings() async throws -> AsyncThrowingStream<[HingeReading], Error> { try await device.readings() }

    func setAngle(_ degrees: Double, timeout: Double) async throws {
        try await device.setAngle(degrees, timeout: timeout)
    }

    func sweep(from: Double, to: Double, seconds: Double, timeout: Double) async throws {
        try await device.sweep(from: from, to: to, seconds: seconds, timeout: timeout)
    }

    func beginSending() async throws -> any AngleSender { LiveSender(sending: try await device.beginSending()) }
    func orientation() async throws -> OrientationName? { try await device.orientation() }

    func setOrientation(_ name: OrientationName, timeout: Double) async throws {
        try await device.setOrientation(name, timeout: timeout)
    }

    func rotate(_ direction: RotationDirection, timeout: Double) async throws -> OrientationName {
        try await device.rotate(direction, timeout: timeout)
    }

    func posture() async throws -> PostureSnapshot { try await device.posture() }
    func screenshot(to path: String) async throws -> ScreenshotOutput { try await device.screenshot(to: path) }
}

/// 送信は、メインアクターの上の 1 つの送信ループからだけ呼ばれる。
struct LiveSender: AngleSender, @unchecked Sendable {
    let sending: HingeSending

    func send(_ degrees: Double) throws { try sending.send(degrees) }
    func flush() { sending.flush() }
}
