import Foundation
import Testing
@testable import HingeCtlCore

// 切断中(トンネルがアイドル)のデバイスを、起こして使う規則のテスト。
// フィクスチャの ID・名前は架空のもの(実機の UDID は使わない)。

private func device(_ n: Int, name: String, state: ConnectionState, transport: String?) -> DeviceEntry {
    DeviceEntry(id: "CCCCCCCC-0000-0000-0000-00000000000\(n)", name: name, udid: "00000000-WAKE00000000000\(n)",
                connectionState: state, transport: transport)
}

private let liveDuo = device(1, name: "Live Duo", state: "connected", transport: "wired")
private let livePhone = device(2, name: "Live Phone", state: "connected", transport: "wired")
private let idleDuo = device(3, name: "Idle Duo", state: "disconnected", transport: "wired")
private let idlePad = device(4, name: "Idle Pad", state: "disconnected", transport: "localNetwork")
private let goneDuo = device(5, name: "Gone Duo", state: "unavailable", transport: nil)
private let noRoute = device(6, name: "No Route", state: "disconnected", transport: nil)

private func awake(_ entry: DeviceEntry) -> DeviceEntry {
    DeviceEntry(id: entry.id, name: entry.name, udid: entry.udid, connectionState: .connected, transport: entry.transport)
}

/// `wake` の呼ばれ方を記録する。`reachable` に含まれるデバイスだけが、つながる(接続中になって返る)
private final class Waker: @unchecked Sendable {
    let reachable: [DeviceEntry]
    private(set) var calls: [[DeviceEntry]] = []
    init(reachable: [DeviceEntry]) { self.reachable = reachable }
    func wake(_ entries: [DeviceEntry]) async -> [DeviceEntry] {
        calls.append(entries)
        return entries.filter(reachable.contains).map(awake)
    }
}

/// `foldable` の名前を持つものだけを「ヒンジに対応する」と答える(起こしたあとの姿でも名前で判断する)
private func narrower(foldable names: Set<String>) -> @Sendable ([DeviceEntry]) async -> [DeviceEntry] {
    { candidates in candidates.filter { names.contains($0.name) } }
}

private func select(_ entries: [DeviceEntry], query: String? = nil, foldable: Set<String>, waker: Waker) async throws -> DeviceEntry {
    try await selectDevice(from: entries, query: query, narrowByCapability: narrower(foldable: foldable), wake: waker.wake)
}

private func message(_ entries: [DeviceEntry], query: String? = nil, foldable: Set<String> = [], waker: Waker) async -> String? {
    do {
        _ = try await select(entries, query: query, foldable: foldable, waker: waker)
        return nil
    } catch let error as CLIError {
        return error.description
    } catch {
        return "予期しないエラー: \(error)"
    }
}

@Suite("切断中のデバイスを起こす")
struct WakeTests {
    // MARK: - 一覧の解析と、起こせるかの判定

    @Test func 起こせるのは_経路がある切断中のデバイスだけ() {
        #expect(idleDuo.isWakeable)                                                     // wired
        #expect(idlePad.isWakeable)                                                     // localNetwork
        #expect(!liveDuo.isWakeable)                                                    // 接続中
        #expect(!goneDuo.isWakeable)                                                    // unavailable(経路なし)
        #expect(!noRoute.isWakeable)                                                    // 経路の情報が無い
        #expect(!device(7, name: "Sim", state: "disconnected", transport: "sameMachine").isWakeable)   // 停止中のシミュレータ
        #expect(!device(8, name: "Odd", state: "unavailable", transport: "wired").isWakeable)          // 切断中ではない
    }

    @Test func 一覧から経路を読む_経路が無いキーはnil() throws {
        let json = Data(#"""
            {"info":{"outcome":"success"},"result":{"devices":[
              {"identifier":"P1","deviceProperties":{"name":"Idle"},"hardwareProperties":{"reality":"physical","udid":"U1"},
               "connectionProperties":{"tunnelState":"disconnected","transportType":"wired"}},
              {"identifier":"P2","deviceProperties":{"name":"Gone"},"hardwareProperties":{"reality":"physical","udid":"U2"},
               "connectionProperties":{"tunnelState":"unavailable"}},
              {"identifier":"P3","deviceProperties":{"name":"Odd"},"hardwareProperties":{"reality":"physical","udid":"U3"},
               "connectionProperties":{"tunnelState":"disconnected","transportType":7}}]}}
            """#.utf8)
        let entries = try decodeDevices(stdout: json, stderr: "", label: "list devices")
        #expect(entries.map(\.transport) == ["wired", nil, nil])          // 型が違う値は、nil として読み飛ばす
        #expect(entries.map(\.isWakeable) == [true, false, false])
    }

    @Test func 経路は一覧の出力に出ない() {
        #expect(encodeJSON([idleDuo]) == #"[{"id":"CCCCCCCC-0000-0000-0000-000000000003","name":"Idle Duo","reality":"physical","state":"disconnected","udid":"00000000-WAKE000000000003"}]"#)
    }

    // MARK: - -d 指定

    @Test func 指定した切断中のデバイスは_起こして使う() async throws {
        let waker = Waker(reachable: [idleDuo])
        let chosen = try await select([liveDuo, idleDuo], query: "Idle Duo", foldable: [], waker: waker)
        #expect(chosen == awake(idleDuo))
        #expect(waker.calls == [[idleDuo]])
    }

    @Test func 起こしてもつながらなければエラー() async {
        let waker = Waker(reachable: [])
        #expect(await message([idleDuo], query: "Idle Duo", waker: waker) == "Idle Duo is not connected (state: disconnected)")
        #expect(waker.calls == [[idleDuo]])
    }

    @Test func 経路が無いデバイスは_起こそうとせず_すぐエラー() async {
        let waker = Waker(reachable: [goneDuo, noRoute])
        #expect(await message([goneDuo], query: "Gone Duo", waker: waker) == "Gone Duo is not reachable (state: unavailable)")
        #expect(await message([noRoute], query: "No Route", waker: waker) == "No Route is not connected (state: disconnected)")
        #expect(waker.calls.isEmpty)
    }

    @Test func 接続中のデバイスは_起こさない() async throws {
        let waker = Waker(reachable: [liveDuo])
        _ = try await select([liveDuo, idleDuo], query: "Live Duo", foldable: [], waker: waker)
        #expect(waker.calls.isEmpty)
    }

    // MARK: - -d 省略

    @Test func 接続中の対応デバイスがあれば_切断中のデバイスには触れない() async throws {
        let waker = Waker(reachable: [idleDuo, idlePad])
        let chosen = try await select([liveDuo, idleDuo, idlePad], foldable: ["Live Duo", "Idle Duo"], waker: waker)
        #expect(chosen == liveDuo)
        #expect(waker.calls.isEmpty)
    }

    @Test func 接続中が無ければ_経路のある切断中のデバイスだけを起こす() async throws {
        let waker = Waker(reachable: [idleDuo, idlePad])
        let chosen = try await select([goneDuo, noRoute, idleDuo, idlePad], foldable: ["Idle Duo"], waker: waker)
        #expect(chosen == awake(idleDuo))
        #expect(waker.calls == [[idleDuo, idlePad]])
    }

    @Test func 接続中の別機種だけで0台なら_切断中のデバイスを起こして絞り直す() async throws {
        let waker = Waker(reachable: [idleDuo])
        let chosen = try await select([livePhone, idleDuo], foldable: ["Idle Duo"], waker: waker)
        #expect(chosen == awake(idleDuo))
        #expect(waker.calls == [[idleDuo]])
    }

    @Test func 起こした端末が対応していなければ_候補を示してエラー() async {
        let waker = Waker(reachable: [idlePad])
        let text = await message([livePhone, idlePad], foldable: [], waker: waker)
        #expect(text == """
            No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:
              \(livePhone.udid)  Live Phone
              \(idlePad.udid)  Idle Pad
            """)
    }

    @Test func 起こしてもつながらなければ_従来のエラー() async {
        let waker = Waker(reachable: [])
        #expect(await message([idleDuo], waker: waker) == "No device is connected (run 'hingectl list' to see devices)")
        let text = await message([livePhone, idleDuo], waker: waker)
        #expect(text == """
            No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:
              \(livePhone.udid)  Live Phone
            """)
        #expect(waker.calls == [[idleDuo], [idleDuo]])
    }

    @Test func 起こす対象が無ければ_wakeを呼ばない() async {
        let waker = Waker(reachable: [goneDuo])
        #expect(await message([goneDuo, noRoute], waker: waker) == "No device is connected (run 'hingectl list' to see devices)")
        #expect(waker.calls.isEmpty)
    }

    @Test func wakeが接続中でないものを返しても_候補にしない() async {
        let text: String? = await {
            do {
                _ = try await selectDevice(from: [idleDuo], query: nil, narrowByCapability: { $0 }, wake: { $0 })
                return nil
            } catch let error as CLIError { return error.description } catch { return "予期しないエラー" }
        }()
        #expect(text == "No device is connected (run 'hingectl list' to see devices)")
    }
}

// MARK: - 起こす順序(ヒンジ対応の見込みがある端末が先)

private func hinted(_ n: Int, name: String, state: ConnectionState = "disconnected", transport: String? = "wired") -> DeviceEntry {
    DeviceEntry(id: "DDDDDDDD-0000-0000-0000-00000000000\(n)", name: name, udid: "00000000-HINT00000000000\(n)",
                connectionState: state, transport: transport, capabilities: [DeviceEntry.orientationControlFeature, "x.other"])
}

@Suite("起こす順序")
struct WakeOrderTests {
    private let hintedDuo = hinted(1, name: "Hinted Duo")
    private let hintedPhone = hinted(2, name: "Hinted Phone")           // 向きは操作できるが、ヒンジは無い(SE のような端末)

    @Test func 見込みがあるかは_向きの遠隔操作の機能で決まる() {
        #expect(hintedDuo.mayHaveHinge)
        #expect(!idlePad.mayHaveHinge)
        let other = DeviceEntry(id: "E", name: "E", udid: "E", connectionState: "disconnected", transport: "wired", capabilities: ["x.other"])
        #expect(!other.mayHaveHinge)
    }

    @Test func 機能の一覧を読む_無いキーと型違いは空() throws {
        let json = Data(#"""
            {"info":{"outcome":"success"},"result":{"devices":[
              {"identifier":"P1","hardwareProperties":{"reality":"physical"},
               "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.remote.devicecontrol.orientation"},
                               {"featureIdentifier":"a.b"},{"featureIdentifier":7},{"other":1}]},
              {"identifier":"P2","hardwareProperties":{"reality":"physical"}},
              {"identifier":"P3","hardwareProperties":{"reality":"physical"},"capabilities":"x"}]}}
            """#.utf8)
        let entries = try decodeDevices(stdout: json, stderr: "", label: "list devices")
        #expect(entries[0].capabilities == [DeviceEntry.orientationControlFeature, "a.b"])
        #expect(entries[0].mayHaveHinge)
        #expect(entries[1].capabilities.isEmpty)
        #expect(entries[2].capabilities.isEmpty)
    }

    @Test func 機能の一覧は_出力に出ない() {
        #expect(encodeJSON([hintedDuo]) == #"[{"id":"DDDDDDDD-0000-0000-0000-000000000001","name":"Hinted Duo","reality":"physical","state":"disconnected","udid":"00000000-HINT000000000001"}]"#)
    }

    @Test func 見込みのある端末だけを先に起こし_見つかれば_残りは起こさない() async throws {
        let waker = Waker(reachable: [hintedDuo, idlePad])
        let chosen = try await select([idlePad, hintedDuo], foldable: ["Hinted Duo"], waker: waker)
        #expect(chosen == awake(hintedDuo))
        #expect(waker.calls == [[hintedDuo]])
    }

    @Test func 見込みのある端末が対応していなければ_残りも起こす() async throws {
        let waker = Waker(reachable: [hintedPhone, idlePad])
        let chosen = try await select([hintedPhone, idlePad], foldable: ["Idle Pad"], waker: waker)
        #expect(chosen == awake(idlePad))
        #expect(waker.calls == [[hintedPhone], [idlePad]])               // 手がかりが外れても、取りこぼさない
    }

    @Test func 見込みのある端末がつながらなくても_残りを起こす() async throws {
        let waker = Waker(reachable: [idlePad])
        let chosen = try await select([hintedDuo, idlePad], foldable: ["Idle Pad"], waker: waker)
        #expect(chosen == awake(idlePad))
        #expect(waker.calls == [[hintedDuo], [idlePad]])
    }

    @Test func 見込みのある端末が無ければ_第1段を飛ばして_全部まとめて起こす() async throws {
        let waker = Waker(reachable: [idleDuo, idlePad])
        _ = try await select([idleDuo, idlePad], foldable: ["Idle Duo"], waker: waker)
        #expect(waker.calls == [[idleDuo, idlePad]])
    }

    @Test func 残りが無ければ_第2段は起こさない() async {
        let waker = Waker(reachable: [])
        #expect(await message([hintedDuo], waker: waker) == "No device is connected (run 'hingectl list' to see devices)")
        #expect(waker.calls == [[hintedDuo]])
    }

    @Test func 見込みのある端末が複数なら_まとめて起こす() async throws {
        let second = hinted(3, name: "Second Hinted")
        let waker = Waker(reachable: [hintedDuo, second])
        _ = try await selectDevice(from: [hintedDuo, second, idlePad], query: nil, narrowByCapability: { $0 },
                                   choose: { $0[0] }, wake: waker.wake)
        #expect(waker.calls == [[hintedDuo, second]])
    }
}

@Suite("起こせなかった理由")
struct WakeFailureReasonTests {
    @Test func 標準出力の_Error_行を取り出す_終了コードが0でも() {
        // 端末がロック中のとき、devicectl は終了コード 0 で、標準出力に理由を出す(実機で確認)
        let stdout = """
            Gathering device information...
            WARNING: Unable to retrieve complete information for this device.
                     Error: The operation failed because the device was still locked.
            Current device information:
            """
        #expect(wakeFailureReason(stdout: stdout, stderr: "", status: 0) == "The operation failed because the device was still locked.")
    }

    @Test func 標準エラーの_Error_行も見る() {
        #expect(wakeFailureReason(stdout: "", stderr: "Error: timed out\n", status: 1) == "timed out")
    }

    @Test func 複数あれば_最初の行() {
        #expect(wakeFailureReason(stdout: "Error: first\nError: second", stderr: "Error: third", status: 1) == "first")
    }

    @Test func Error_行が無くて終了コードが0以外なら_終了コードを理由にする() {
        #expect(wakeFailureReason(stdout: "x", stderr: "y", status: 3) == "exit status 3")
    }

    @Test func 成功で_理由もなければ_nil() {
        #expect(wakeFailureReason(stdout: "Current device information:", stderr: "", status: 0) == nil)
        #expect(wakeFailureReason(stdout: "", stderr: "", status: 0) == nil)
    }
}
