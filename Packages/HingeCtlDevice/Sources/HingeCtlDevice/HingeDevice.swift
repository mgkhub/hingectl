@_implementationOnly import CoreDevice
import Foundation
import HingeCtlCore

// CLI と GUI が使う、公開 API。CoreDevice の型は外へ出さず、Swift の型だけを受け渡す。
// 個々の処理は DeviceAccess.swift / Devicectl.swift にある。

/// 連続送信用の送り手。`send` は流し切らずに送るので、最後に `flush()` を 1 回呼ぶ。
public struct HingeSending {
    let sender: HingeSender

    public func send(_ degrees: Double) throws { try sender.send(degrees, barrier: false) }
    public func flush() { sender.flush() }
}

/// 選択された 1 台のデバイス(実機またはシミュレータ)。
public struct HingeDevice: @unchecked Sendable {
    public let entry: DeviceEntry
    // CoreDevice の型を、保存プロパティの型にしない(公開の型に出さずに隠すため)。取り出しは `remote`。
    private let handle: AnyObject
    var remote: RemoteDevice { handle as! RemoteDevice }

    init(entry: DeviceEntry, remote: RemoteDevice) {
        self.entry = entry
        handle = remote
    }

    /// `query` からデバイスを 1 台に絞る(`-d` の規則。切断中のデバイスは起こす)。
    /// `choose` は、ヒンジ対応のデバイスが複数あるときの選択(nil なら、エラーにする)。
    public static func resolve(_ query: String?, choose: (([DeviceEntry]) async throws -> DeviceEntry)? = nil) async throws -> HingeDevice {
        let (remote, entry) = try await resolveRemoteDevice(query, choose: choose)
        return HingeDevice(entry: entry, remote: remote)
    }

    /// 一覧のエントリを、選択の規則を通さずに開く(GUI 用。切断中のデバイスは、先に `wakeDevices` で起こす)。
    public static func open(_ entry: DeviceEntry) async throws -> HingeDevice {
        guard let remote = await RemoteDirectory(entries: [entry]).remote(for: entry) else {
            throw CLIError("CoreDevice does not recognize \(entry.name)")
        }
        return HingeDevice(entry: entry, remote: remote)
    }

    /// ヒンジ角に対応しているか(非対応と、問い合わせの失敗を区別する)。
    public func support() async -> HingeSupport { await hingeSupport(remote) }

    /// 対応していなければ、何も送らずにエラーにする。
    public func requireHinge() async throws { try await HingeCtlDevice.requireHinge(remote, name: entry.name) }

    public func readAngle(timeout: Double = 2) async throws -> HingeReading {
        try await readHingeAngle(remote, timeout: timeout)
    }

    /// ヒンジ角の購読。開始直後に現在値が届く。列のエラーは、原因つきの `CLIError` になる。
    public func readings() async throws -> AsyncThrowingStream<[HingeReading], Error> {
        let upstream = try await openHingeReadings(remote)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await batch in upstream { continuation.yield(batch) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: hingeStreamFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func setAngle(_ degrees: Double, timeout: Double) async throws {
        try await setHingeAngle(remote, degrees: degrees, timeout: timeout)
    }

    public func sweep(from: Double, to: Double, seconds: Double, timeout: Double) async throws {
        try await sweepHingeAngle(remote, deviceID: entry.id, from: from, to: to, seconds: seconds, timeout: timeout)
    }

    public func beginSending() async throws -> HingeSending {
        HingeSending(sender: try await HingeSender(device: remote))
    }

    public func orientation() async throws -> OrientationName? { try await currentOrientation(remote) }

    public func setOrientation(_ name: OrientationName, timeout: Double) async throws {
        try await HingeCtlDevice.setOrientation(remote, name: name, timeout: timeout)
    }

    public func rotate(_ direction: RotationDirection, timeout: Double) async throws -> OrientationName {
        try await rotateOrientation(remote, direction: direction, timeout: timeout)
    }

    /// ヒンジ非対応のデバイス(`unsupported`)では、読めない項目があっても全体を失敗させず、読めたものを返す
    /// (角度は読まずに nil。向き・ディスプレイが読めない場合は、警告を出して同様に扱う)。
    /// ヒンジ対応のデバイスと、対応かどうか分からない(問い合わせの失敗)デバイスでは、
    /// 角度・向き・ディスプレイのどれかが読めなければ失敗する。
    public func posture() async throws -> PostureSnapshot {
        let support = await hingeSupport(remote)
        if case .unknown(let reason) = support { HingeLog.warn("cannot determine whether \(entry.name) supports the hinge: \(reason)") }
        let tolerant = support == .unsupported
        // 非対応のデバイスだけが、読まずに nil。対応・不明のデバイスで読めなければ、失敗する(`null` と取り違えないため)
        let reading = try await postureAngle(support: support) { try await readHingeAngle(remote) }
        let mechanicalAngle = reading?.mechanicalAngle
        let sensorAngle = reading?.sensorAngle
        let orientation: OrientationField
        do {
            orientation = try await currentOrientation(remote).map(OrientationField.known) ?? .unknown
        } catch {
            guard tolerant else { throw error }
            HingeLog.warn("cannot read the orientation: \(error)")
            orientation = .unavailable
        }
        var displays: [DisplayState] = []
        var active: Int?
        do {
            (displays, active) = try readDisplays(deviceID: entry.id)
        } catch {
            guard tolerant else { throw error }
            HingeLog.warn("cannot read the displays: \(error)")
        }
        return PostureSnapshot(mechanicalAngle: mechanicalAngle, sensorAngle: sensorAngle, orientation: orientation, displays: displays, active: active)
    }

    /// UI を載せているディスプレイの PNG を保存する。
    /// 折りたたんだ直後は、ディスプレイが active でもバックライトが遅れて点くため、少し待つ。
    public func screenshot(to path: String) async throws -> ScreenshotOutput {
        var state = try readDisplays(deviceID: entry.id)
        var attempt = 0
        // 消灯(`off`)の間だけ待つ。報告の無い(`unknown`)デバイスでは、待っても変わらないので待たない。
        while let index = state.active, state.displays[index].backlight == .off, attempt < 8 {
            try await Task.sleep(for: .milliseconds(250))
            state = try readDisplays(deviceID: entry.id)
            attempt += 1
        }
        guard let index = state.active else { throw CLIError("No display is hosting the UI (is the device still booting?)") }
        let display = state.displays[index]
        if display.backlight == .off {
            HingeLog.warn("\(display.name) is active but its backlight is off; the image may be black")
        }

        let destinationURL = URL(fileURLWithPath: path).standardizedFileURL
        try? FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = destinationURL.path
        var arguments = ["device", "capture", "screenshot", "--device", entry.id, "--destination", destination]
        // ディスプレイが 1 つなら指定は不要で、指定を拒否する OS もある
        if state.displays.count > 1 && !display.uniqueId.isEmpty { arguments += ["--display-unique-id", display.uniqueId] }
        let run = try runDevicectl(arguments)
        guard run.status == 0 else {
            let output = (String(decoding: run.stdout, as: UTF8.self) + run.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("Failed to take a screenshot of \(display.name): \(output)")
        }
        return ScreenshotOutput(display: display.name, path: destination)
    }
}
