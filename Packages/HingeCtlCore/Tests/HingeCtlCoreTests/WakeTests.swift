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

    @Test func CoreDeviceレコードから経路を読む_経路が無いキーや型違いはnil() throws {
        func record(id: String, name: String, udid: String, state: String, transport: Any?) -> Data {
            var values: [[String: Any]] = [
                ["descriptorIdentifier": ["key": "name"], "value": name],
                ["descriptorIdentifier": ["key": "reality"], "value": "physical"],
                ["descriptorIdentifier": ["key": "udid"], "value": udid],
                ["descriptorIdentifier": ["key": "state"], "value": state],
            ]
            if let transport {
                values.append(["descriptorIdentifier": ["key": "transportType"], "value": transport])
            }
            return try! JSONSerialization.data(withJSONObject: ["identifier": id, "values": values])
        }
        let entries = [
            try #require(decodeCoreDeviceRecord(data: record(id: "P1", name: "Idle", udid: "U1", state: "disconnected", transport: "wired"))),
            try #require(decodeCoreDeviceRecord(data: record(id: "P2", name: "Gone", udid: "U2", state: "unavailable", transport: nil))),
            try #require(decodeCoreDeviceRecord(data: record(id: "P3", name: "Odd", udid: "U3", state: "disconnected", transport: 7))),
        ]
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
