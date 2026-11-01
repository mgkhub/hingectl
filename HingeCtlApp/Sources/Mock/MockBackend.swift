import AppKit
import Foundation
import HingeCtlAppKit
import HingeCtlCore

/// 撮影用の偽のバックエンド(`--screenshot-mode` のときだけ使う)。実機がなくても、README のスクリーンショットを撮れる。
/// 値は固定で、実行のたびに同じ画面になる(ヒンジ角の購読は、最初の 1 回だけ流す)。
struct MockBackend: HingeBackend {
    static let entries: [DeviceEntry] = [
        DeviceEntry(
            id: "5E1C0D52-7B3A-4F0E-9C61-2A84D3B7E910", name: "iPhone Duo", udid: "00008160-000A1B2C3D4E5F60",
            connectionState: .connected, transport: "wired", osName: "iOS", osVersion: "27.1", osBuild: "24A94425"),
        DeviceEntry(
            id: "18E675CA-0F2A-4035-8124-C4121925CEA9", name: "iPhone Duo", udid: "18E675CA-0F2A-4035-8124-C4121925CEA9",
            connectionState: .connected, reality: .simulated, transport: "sameMachine", osName: "iOS", osVersion: "27.1", osBuild: "24A94425"),
        DeviceEntry(
            id: "A3F7B8C1-2D4E-4A60-8B15-9E0C7D6F5A42", name: "iPad mini", udid: "00008130-001C2E3A4B5C6D70",
            connectionState: .disconnected, transport: "wired", osName: "iPadOS", osVersion: "27.0", osBuild: "24A5301"),
        DeviceEntry(
            id: "C9D2E4F6-1A3B-4C5D-8E7F-0A1B2C3D4E5F", name: "iPhone SE", udid: "00008110-000E9F8A7B6C5D40",
            connectionState: .unavailable, osName: "iOS", osVersion: "26.5", osBuild: "23F77"),
    ]

    func listDevices() async throws -> [DeviceEntry] { Self.entries }
    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry] { entries }
    func open(_ entry: DeviceEntry) async throws -> any HingeSession { MockSession() }
}

final class MockSession: HingeSession, @unchecked Sendable {
    static let angle = 118.4

    /// 購読を開いたままにする(継続を手放すと、ストリームが終わり、画面に「切れた」という警告が出る)
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<[HingeReading], Error>.Continuation?

    func support() async -> HingeSupport { .supported }

    func readings() async throws -> AsyncThrowingStream<[HingeReading], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([HingeReading(mechanicalAngle: Self.angle, sensorAngle: Self.angle, isValid: true,
                                             minAngle: 0, maxAngle: 180, timestamp: 0)])
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func setAngle(_ degrees: Double, timeout: Double) async throws {}
    func sweep(from: Double, to: Double, seconds: Double, timeout: Double) async throws {}
    func beginSending() async throws -> any AngleSender { MockSender() }
    func orientation() async throws -> OrientationName? { .portrait }
    func setOrientation(_ name: OrientationName, timeout: Double) async throws {}
    func rotate(_ direction: RotationDirection, timeout: Double) async throws -> OrientationName { .portrait.rotated(direction) }

    func posture() async throws -> PostureSnapshot {
        // 半開き: 内側(LCD-1)が、UI を載せている
        PostureSnapshot(
            mechanicalAngle: Self.angle,
            sensorAngle: Self.angle,
            orientation: .known(.portrait),
            displays: [
                DisplayState(name: "LCD", uniqueId: "B3F2-LCD", displayId: 1, primary: true, active: false, backlight: .off,
                             width: 1206, height: 2622, scale: 3),
                DisplayState(name: "LCD-1", uniqueId: "B3F2-LCD-1", displayId: 2, primary: false, active: true, backlight: .lit("on"),
                             width: 1840, height: 2224, scale: 2),
            ],
            active: 1)
    }

    func screenshot(to path: String) async throws -> ScreenshotOutput {
        try MockScreenshot.png().write(to: URL(fileURLWithPath: path))
        return ScreenshotOutput(display: "LCD-1", path: path)
    }
}

struct MockSender: AngleSender {
    func send(_ degrees: Double) throws {}
    func flush() {}
}

/// 「撮影」の結果に出す画像。風景(アイコンと同じ色)を、固定の寸法で描く。
enum MockScreenshot {
    static let size = NSSize(width: 1500, height: 1000)

    static func png() throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(deviceRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func fill(_ hex: UInt32, _ points: [NSPoint]) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        color(hex).setFill()
        path.fill()
    }

    /// 原点は左下。y は、画面の上端を 1 として、割合で書く
    private static func draw() {
        let w = size.width, h = size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * w, y: (1 - y) * h) }
        color(0xB9CDE4).setFill()
        NSRect(origin: .zero, size: size).fill()
        fill(0xECDFCC, [p(0, 0.5), p(1, 0.5), p(1, 1), p(0, 1)])
        fill(0x6F7664, [p(0, 0.62), p(0.15, 0.50), p(0.30, 0.58), p(0.46, 0.40), p(0.62, 0.55), p(0.78, 0.46), p(1, 0.60), p(1, 1), p(0, 1)])
        fill(0xDCCFB8, [p(0, 0.76), p(0.20, 0.70), p(0.50, 0.74), p(1, 0.72), p(1, 1), p(0, 1)])
        fill(0xC4B69B, [p(0, 0.88), p(0.35, 0.80), p(0.70, 0.82), p(1, 0.90), p(1, 1), p(0, 1)])
    }
}
