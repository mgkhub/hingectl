import Foundation
import HingeCtlCore

// devicectl(公開 CLI)を子プロセスで呼ぶ部分。
// デバイス一覧(ハードウェア UDID・名前の解決)、ディスプレイ情報、スクリーンショットに使う。
// 出力の解析は HingeCtlCore(Devices.swift / Displays.swift)にある。

struct DevicectlResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

/// `xcrun devicectl <arguments>` を実行して出力を集める。
/// どの Xcode の devicectl を使うかは、環境変数 DEVELOPER_DIR か xcode-select の選択に従う
/// (CoreDevice はシステム共通。シミュレータと実機(iOS 27.1)のどちらでも、Xcode 27.0 / 27.1 のどちらの devicectl でも、使うコマンドの出力が同じことを確認した)。
func runDevicectl(_ arguments: [String]) throws -> DevicectlResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["devicectl"] + arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do { try process.run() } catch { throw CLIError("Cannot run devicectl: \(error)") }

    // 標準エラーが詰まって止まらないよう、別スレッドで読む
    final class Box: @unchecked Sendable { var data = Data() }
    let errBox = Box()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    group.wait()
    return DevicectlResult(status: process.terminationStatus, stdout: out, stderr: String(decoding: errBox.data, as: UTF8.self))
}

/// 切断中のデバイスの接続を張るときの、devicectl の上限(秒)。応答しない端末で、固まらないようにする。
private let wakeTimeoutSeconds = 10

/// 切断中(トンネルがアイドル)のデバイスの接続を張り、**つながったものを、最新の状態で**返す。
///
/// CoreDevice の API は接続を張らず、切断中は、ヒンジ対応のデバイスにも「非対応」(1001)と返す。
/// 一方 devicectl は、必要なときに自分で接続を張るため、`device info details` を呼んで接続を起こす。
/// コマンドの成否は見ず、判定は、取り直した一覧の `connected` で行う。
public func wakeDevices(_ entries: [DeviceEntry]) async -> [DeviceEntry] {
    guard !entries.isEmpty else { return [] }
    HingeLog.note("connecting to \(entries.map(\.name).joined(separator: ", "))...")
    let failures = await withTaskGroup(of: (id: String, reason: String).self) { group in
        for entry in entries {
            group.addTask {
                let arguments = ["device", "info", "details", "--device", entry.id, "--timeout", "\(wakeTimeoutSeconds)"]
                guard let run = try? runDevicectl(arguments) else { return (entry.id, "cannot run devicectl") }
                // 失敗しても終了コードが 0 のことがある(例: 端末がロック中)。理由は、`Error:` の行から拾う
                let reason = wakeFailureReason(stdout: String(decoding: run.stdout, as: UTF8.self), stderr: run.stderr, status: run.status)
                return (entry.id, reason ?? "")
            }
        }
        var reasons: [String: String] = [:]
        for await result in group { reasons[result.id] = result.reason }
        return reasons
    }
    let refreshed: [DeviceEntry]
    do {
        refreshed = try listDevices()
    } catch {
        // 状態が分からないので、端末ごとの「つながらない」は出さない(つながっていても、誤った警告になるため)
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

/// 引数の先頭 3 語(エラーメッセージの見出し)。例: "list devices"、"device info displays"
private func label(_ arguments: [String]) -> String { arguments.prefix(3).joined(separator: " ") }

/// 実機と、起動中のシミュレータの一覧
public func listDevices() throws -> [DeviceEntry] {
    let arguments = ["list", "devices"]
    let run = try runDevicectl(arguments + ["-q", "-j", "-"])
    return try decodeDevices(stdout: run.stdout, stderr: run.stderr, label: label(arguments))
}

/// 内蔵ディスプレイの状態と、UI を載せているディスプレイの添字
public func readDisplays(deviceID: String) throws -> (displays: [DisplayState], active: Int?) {
    let arguments = ["device", "info", "displays", "--device", deviceID]
    let run = try runDevicectl(arguments + ["-q", "-j", "-"])
    return try decodeDisplays(stdout: run.stdout, stderr: run.stderr, label: label(arguments))
}

/// 折りたたみ・展開のあと、UI を載せるディスプレイの切り替えを待つ。
/// `before` は、移動前に UI を載せていたディスプレイの uniqueId。
///
/// - UI を載せるディスプレイ(active)が `before` から変わり、新しい側のバックライトが点灯したら、
///   そこから `settle` 秒だけ待って戻る。
/// - 約 1 秒待っても変わらない場合(切り替えの無い角度への移動): そこで待ちを打ち切る。
/// 全体の上限は `maxSeconds`。読み取りに失敗した場合は、警告を出して待たずに戻る。
///
/// 実機の Duo(較正で計測)では、閉じるとき active は約 0.7 秒で背面へ切り替わり、新しい側は点灯済みだった。
/// 内側のバックライトはその後も約 3.5 秒点いたままだが、それを待つと長すぎたため、待たない。
func waitForDisplaySettle(deviceID: String, before: String?, settle: Double, maxSeconds: Double = 6) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(maxSeconds)
    let initialLimit = clock.now + .seconds(1)
    var switchedAt: ContinuousClock.Instant?
    let settleDuration = Duration.seconds(settle)
    while clock.now < deadline {
        guard let state = try? readDisplays(deviceID: deviceID) else {
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
