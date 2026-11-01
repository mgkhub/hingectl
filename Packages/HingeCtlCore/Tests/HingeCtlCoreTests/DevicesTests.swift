import Foundation
import Testing
@testable import HingeCtlCore

// フィクスチャの ID・名前は架空のもの(実機の UDID は使わない)。

private func device(id: String, name: String, udid: String, state: ConnectionState = "connected",
                    reality: DeviceReality = .physical) -> DeviceEntry {
    DeviceEntry(id: id, name: name, udid: udid, connectionState: state, reality: reality)
}

private let duo = device(id: "AAAAAAAA-0000-0000-0000-000000000001", name: "Test Duo", udid: "00000000-DUO0000000000001")
private let phone = device(id: "AAAAAAAA-0000-0000-0000-000000000002", name: "Test Phone", udid: "00000000-PHONE00000000002")
private let away = device(id: "AAAAAAAA-0000-0000-0000-000000000003", name: "Away Pad", udid: "00000000-PAD0000000000003", state: "disconnected")
/// 起動中のシミュレータ(識別子は UDID と同じ)
private let simDuo = device(id: "BBBBBBBB-0000-0000-0000-000000000001", name: "Sim Duo", udid: "BBBBBBBB-0000-0000-0000-000000000001", reality: .simulated)
private let simPhone = device(id: "BBBBBBBB-0000-0000-0000-000000000002", name: "Sim Phone", udid: "BBBBBBBB-0000-0000-0000-000000000002", reality: .simulated)

/// `selectDevice` を呼び、CLIError のメッセージを返す(成功なら nil)
private func selectionError(_ entries: [DeviceEntry], query: String?,
                            narrow: @escaping ([DeviceEntry]) async -> [DeviceEntry] = { $0 }) async -> String? {
    do {
        _ = try await selectDevice(from: entries, query: query, narrowByCapability: narrow)
        return nil
    } catch let error as CLIError {
        return error.description
    } catch {
        return "予期しないエラー: \(error)"
    }
}

@Suite("devicectl の JSON と実機の選択")
struct DevicesTests {
    // MARK: - 一覧の解析

    private func listResponse(_ devices: String) -> Data {
        Data(#"{"info":{"outcome":"success"},"result":{"devices":[\#(devices)]}}"#.utf8)
    }

    private func decode(_ devices: String) throws -> [DeviceEntry] {
        try decodeDevices(stdout: listResponse(devices), stderr: "", label: "list devices")
    }

    private func record(id: String?, name: String?, reality: String?, udid: String?, state: String?) -> String {
        var fields: [String] = []
        if let id { fields.append(#""identifier":"\#(id)""#) }
        if let name { fields.append(#""deviceProperties":{"name":"\#(name)"}"#) }
        var hardware: [String] = []
        if let reality { hardware.append(#""reality":"\#(reality)""#) }
        if let udid { hardware.append(#""udid":"\#(udid)""#) }
        fields.append(#""hardwareProperties":{\#(hardware.joined(separator: ","))}"#)
        if let state { fields.append(#""connectionProperties":{"tunnelState":"\#(state)"}"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test func OSのバージョンとビルドと名前を読む() throws {
        let json = #"""
            {"identifier":"P1","deviceProperties":{"name":"iPhone Duo","osVersionNumber":"27.1","osBuildUpdate":"24A94425"},
             "hardwareProperties":{"reality":"physical","udid":"U1","platform":"iOS","deviceType":"iPhone"},
             "connectionProperties":{"tunnelState":"disconnected"}},
            {"identifier":"P2","deviceProperties":{"name":"iPad mini","osVersionNumber":"27.2","osBuildUpdate":"24B119"},
             "hardwareProperties":{"reality":"physical","udid":"U2","platform":"iOS","deviceType":"iPad"},
             "connectionProperties":{"tunnelState":"disconnected"}}
            """#
        let entries = try decode(json)
        #expect(entries.map(\.osText) == ["iOS 27.1", "iPadOS 27.2"])
        #expect(entries.map(\.osBuild) == ["24A94425", "24B119"])
    }

    @Test func OSの情報が無い_または型が違えば_nilになり_ほかの項目は読める() throws {
        let json = #"""
            {"identifier":"P1","deviceProperties":{"name":"Watch"},"hardwareProperties":{"reality":"physical","udid":"U1","platform":"watchOS"}},
            {"identifier":"P2","deviceProperties":{"name":"X","osVersionNumber":27,"osBuildUpdate":false},
             "hardwareProperties":{"reality":"physical","udid":"U2","platform":7,"deviceType":[]}}
            """#
        let entries = try decode(json)
        #expect(entries.map(\.osVersion) == [nil, nil])
        #expect(entries.map(\.osText) == [nil, nil])
        #expect(entries.map(\.name) == ["Watch", "X"])
        #expect(entries[0].osName == "watchOS")
    }

    @Test func バージョンがあって名前が無ければ_OSと表示する() {
        let entry = DeviceEntry(id: "i", name: "n", udid: "u", connectionState: "connected", osVersion: "27.1")
        #expect(entry.osText == "OS 27.1")
    }

    @Test func OSの情報は_listのJSONにも_一覧の行にも出ない() {
        let entry = DeviceEntry(id: "i", name: "n", udid: "u", connectionState: "connected",
                                osName: "iOS", osVersion: "27.1", osBuild: "24A")
        let plain = DeviceEntry(id: "i", name: "n", udid: "u", connectionState: "connected")
        #expect(encodeJSON(entry) == encodeJSON(plain))
        #expect(listLine(entry) == listLine(plain))
    }

    @Test func 実機と起動中のシミュレータだけを返し_実機が先() throws {
        let devices = try decode([
            record(id: "S1", name: "Sim", reality: "simulated", udid: "S1", state: "connected"),         // 起動中のシミュレータ
            record(id: "S2", name: "Off", reality: "simulated", udid: "S2", state: "disconnected"),      // 未起動のシミュレータは除外
            record(id: "P1", name: "Real", reality: "physical", udid: "U1", state: "connected"),
            record(id: "P0", name: "Away", reality: "physical", udid: "U0", state: "disconnected"),     // 実機は未接続でも返す
            record(id: nil, name: "NoId", reality: "physical", udid: nil, state: nil),
            record(id: "W1", name: "Watch", reality: nil, udid: "UW", state: "disconnected"),           // reality が無いものは除外
            record(id: "X1", name: "Other", reality: "other", udid: "UX", state: "connected"),          // 未知の reality は除外
        ].joined(separator: ","))
        #expect(devices == [
            DeviceEntry(id: "P1", name: "Real", udid: "U1", connectionState: "connected"),
            DeviceEntry(id: "P0", name: "Away", udid: "U0", connectionState: "disconnected"),
            DeviceEntry(id: "S1", name: "Sim", udid: "S1", connectionState: "connected", reality: .simulated),
        ])
    }

    @Test func 接続状態が不明なシミュレータは除外する() throws {
        #expect(try decode(record(id: "S3", name: "Sim", reality: "simulated", udid: "S3", state: nil)).isEmpty)
    }

    @Test func 欠けた項目は既定値で補う() throws {
        let devices = try decode(record(id: "P2", name: nil, reality: "physical", udid: nil, state: nil))
        #expect(devices == [DeviceEntry(id: "P2", name: "(unnamed)", udid: "P2", connectionState: "unknown")])
        #expect(try decodeDevices(stdout: Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8), stderr: "", label: "list devices").isEmpty)
    }

    @Test func 型の違う項目だけが既定値に落ち_未知のキーは無視される() throws {
        let json = #"""
            {"identifier":"P3","extra":{"a":[1,2]},"deviceProperties":{"name":7,"other":true},
             "hardwareProperties":{"reality":"physical","udid":["x"]},"connectionProperties":{"tunnelState":false}}
            """#
        #expect(try decode(json) == [DeviceEntry(id: "P3", name: "(unnamed)", udid: "P3", connectionState: "unknown")])
        // 入れ子の項目そのものが壊れていても、ほかの項目は読める
        let nested = #"{"identifier":"P4","deviceProperties":"x","hardwareProperties":{"reality":"physical","udid":"U4"},"connectionProperties":[]}"#
        #expect(try decode(nested) == [DeviceEntry(id: "P4", name: "(unnamed)", udid: "U4", connectionState: "unknown")])
    }

    @Test func 配列の壊れた要素だけが除外される() throws {
        let devices = try decode(#"1,"x",null,[],"#
            + record(id: "P5", name: "Ok", reality: "physical", udid: "U5", state: "connected"))
        #expect(devices.map(\.id) == ["P5"])
    }

    @Test func devicesが配列でなければ空() throws {
        let data = Data(#"{"info":{"outcome":"success"},"result":{"devices":"x"}}"#.utf8)
        #expect(try decodeDevices(stdout: data, stderr: "", label: "list devices").isEmpty)
    }

    @Test func 失敗した出力はstderrを添えてエラー() {
        let failure = #"{"info":{"outcome":"failed"}}"#
        for (stdout, stderr, expected) in [
            (failure, "boom\n", "devicectl list devices failed: boom"),
            (failure, "", "devicectl list devices failed"),
            ("not json", "", "devicectl list devices failed"),
        ] {
            do {
                _ = try decodeDevices(stdout: Data(stdout.utf8), stderr: stderr, label: "list devices")
                Issue.record("エラーになるはず: \(stdout)")
            } catch let error as CLIError {
                #expect(error.description == expected)
            } catch {
                Issue.record("予期しないエラー: \(error)")
            }
        }
    }

    @Test func 一覧の行は実機では従来と同じで_シミュレータには印が付く() {
        #expect(listLine(duo) == "00000000-DUO0000000000001  Test Duo  (connected)")
        #expect(listLine(away) == "00000000-PAD0000000000003  Away Pad  (disconnected)")
        #expect(listLine(simDuo) == "BBBBBBBB-0000-0000-0000-000000000001  Sim Duo  (connected)  [simulator]")
    }

    @Test func 接続中かどうか() {
        #expect(duo.isConnected)
        #expect(!away.isConnected)
    }

    // MARK: - -d の照合

    @Test func 識別子_UDID_名前で1台に絞れる() async throws {
        let entries = [duo, phone, away]
        for query in [duo.id, duo.udid, duo.name] {
            #expect(try await selectDevice(from: entries, query: query, narrowByCapability: { $0 }) == duo, "\(query)")
        }
    }

    @Test func 識別子とUDIDは大文字小文字を区別しないが_名前は完全一致() async {
        let entries = [duo, phone]
        #expect(await selectionError(entries, query: duo.id.lowercased()) == nil)
        #expect(await selectionError(entries, query: duo.udid.lowercased()) == nil)
        #expect(await selectionError(entries, query: duo.name.lowercased()) == "No device matches: test duo (run 'hingectl list' to see devices)")
    }

    @Test func 一致なしはエラー() async {
        #expect(await selectionError([duo], query: "nothing") == "No device matches: nothing (run 'hingectl list' to see devices)")
    }

    @Test func 名前が複数に一致するとUDIDを促す() async {
        let twin = device(id: "AAAAAAAA-0000-0000-0000-000000000009", name: "Test Duo", udid: "00000000-DUO0000000000009")
        let message = await selectionError([duo, twin], query: "Test Duo")
        #expect(message == """
            Several devices match "Test Duo"; specify the UDID:
              \(duo.udid)  Test Duo
              \(twin.udid)  Test Duo
            """)
    }

    @Test func 接続されていない実機は指定してもエラー() async {
        #expect(await selectionError([duo, away], query: "Away Pad") == "Away Pad is not connected (state: disconnected)")
    }

    // MARK: - -d なし

    /// 絞り込みの呼ばれ方(渡された候補の列)を記録し、`foldable` に含まれるものだけを「対応する」と答える
    private final class Narrower: @unchecked Sendable {
        let foldable: [DeviceEntry]
        private(set) var calls: [[DeviceEntry]] = []
        init(foldable: [DeviceEntry]) { self.foldable = foldable }
        func narrow(_ candidates: [DeviceEntry]) async -> [DeviceEntry] {
            calls.append(candidates)
            return candidates.filter(foldable.contains)
        }
    }

    /// 問い合わせの呼ばれ方を記録し、`pick` 番目(0 始まり)の候補を選ぶ
    private final class Chooser: @unchecked Sendable {
        let pick: Int
        private(set) var calls: [[DeviceEntry]] = []
        init(pick: Int = 0) { self.pick = pick }
        func choose(_ candidates: [DeviceEntry]) async throws -> DeviceEntry {
            calls.append(candidates)
            return candidates[pick]
        }
    }

    private func select(_ entries: [DeviceEntry], foldable: [DeviceEntry], chooser: Chooser? = nil) async throws -> (DeviceEntry, Narrower) {
        let narrower = Narrower(foldable: foldable)
        let chosen = try await selectDevice(from: entries, query: nil, narrowByCapability: narrower.narrow,
                                            choose: chooser.map { chooser in { try await chooser.choose($0) } })
        return (chosen, narrower)
    }

    @Test func 接続中がなければエラー() async {
        #expect(await selectionError([away], query: nil) == "No device is connected (run 'hingectl list' to see devices)")
        #expect(await selectionError([], query: nil) == "No device is connected (run 'hingectl list' to see devices)")
    }

    @Test func 対応するデバイスがちょうど1台なら_問い合わせずにそれを選ぶ() async throws {
        let chooser = Chooser()
        let (chosen, narrower) = try await select([duo, phone, away], foldable: [duo], chooser: chooser)
        #expect(chosen == duo)
        #expect(narrower.calls == [[duo, phone]])       // 接続中のデバイスが、対応の絞り込みに渡される
        #expect(chooser.calls.isEmpty)
    }

    @Test func 接続中が1台でも_ヒンジ対応を確認する() async throws {
        let (chosen, narrower) = try await select([duo, away], foldable: [duo])
        #expect(chosen == duo)
        #expect(narrower.calls == [[duo]])
        let message = await selectionError([phone], query: nil, narrow: { _ in [] })
        #expect(message == """
            No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:
              \(phone.udid)  Test Phone
            """)
    }

    @Test func シミュレータだけが対応していれば_それを選ぶ() async throws {
        let (chosen, narrower) = try await select([phone, simDuo], foldable: [simDuo])
        #expect(chosen == simDuo)
        #expect(narrower.calls == [[phone, simDuo]])
    }

    @Test func 実機とシミュレータの両方が対応していれば_問い合わせる() async throws {
        let chooser = Chooser(pick: 1)
        let (chosen, _) = try await select([duo, phone, simDuo], foldable: [duo, simDuo], chooser: chooser)
        #expect(chosen == simDuo)                       // 選んだ側(実機を優先しない)
        #expect(chooser.calls == [[duo, simDuo]])       // 対応する候補だけが渡される。実機が先
    }

    @Test func 同種が複数台でも問い合わせる() async throws {
        let twin = device(id: "AAAAAAAA-0000-0000-0000-000000000009", name: "Test Duo", udid: "00000000-DUO0000000000009")
        let chooser = Chooser(pick: 1)
        let (chosen, _) = try await select([duo, twin], foldable: [duo, twin], chooser: chooser)
        #expect(chosen == twin)
        let (second, _) = try await select([simDuo, simPhone], foldable: [simDuo, simPhone], chooser: Chooser(pick: 0))
        #expect(second == simDuo)
    }

    @Test func 問い合わせができなければ_推測せずに候補を示してエラー() async {
        let message = await selectionError([duo, phone, simDuo], query: nil, narrow: { $0 })
        #expect(message == """
            Cannot narrow down to one device; specify one with -d <udid|name>:
              \(duo.udid)  Test Duo
              \(phone.udid)  Test Phone
              \(simDuo.udid)  Sim Duo  [simulator]
            """)
    }

    @Test func どれも対応していなければ_接続中の全部を示してエラー() async {
        let message = await selectionError([phone, simDuo], query: nil, narrow: { _ in [] })
        #expect(message == """
            No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:
              \(phone.udid)  Test Phone
              \(simDuo.udid)  Sim Duo  [simulator]
            """)
    }

    @Test func 問い合わせが中止されたらそのエラーが伝わる() async {
        struct Cancelled: Error {}
        do {
            _ = try await selectDevice(from: [duo, simDuo], query: nil, narrowByCapability: { $0 }, choose: { _ in throw Cancelled() })
            Issue.record("エラーになるはず")
        } catch is Cancelled {
        } catch {
            Issue.record("予期しないエラー: \(error)")
        }
    }

    // MARK: - -d あり(対応の有無は問わない)

    @Test func dを指定すれば_非対応のデバイスも選べ_絞り込みも問い合わせもしない() async throws {
        let chooser = Chooser()
        let chosen = try await selectDevice(from: [duo, phone, simDuo], query: phone.name,
                                            narrowByCapability: { _ in Issue.record("絞り込みは不要"); return [] },
                                            choose: { try await chooser.choose($0) })
        #expect(chosen == phone)
        #expect(chooser.calls.isEmpty)
    }

    @Test func シミュレータも識別子_名前で指定できる() async throws {
        let entries = [duo, simDuo]
        for query in [simDuo.id, simDuo.id.lowercased(), simDuo.name] {
            #expect(try await selectDevice(from: entries, query: query, narrowByCapability: { $0 }) == simDuo, "\(query)")
        }
    }

    @Test func 名前が実機とシミュレータで一致するとUDIDを促し_シミュレータには印が付く() async {
        let twin = device(id: "BBBBBBBB-0000-0000-0000-000000000009", name: "Test Duo", udid: "BBBBBBBB-0000-0000-0000-000000000009", reality: .simulated)
        #expect(await selectionError([duo, twin], query: "Test Duo") == """
            Several devices match "Test Duo"; specify the UDID:
              \(duo.udid)  Test Duo
              \(twin.udid)  Test Duo  [simulator]
            """)
    }

    // MARK: - 問い合わせの表示と入力

    @Test func 問い合わせの表示は番号つきで_シミュレータには印が付く() {
        #expect(choicePromptLines([duo, simDuo]) == [
            "Several connected devices support the hinge:",
            "  1) \(duo.udid)  Test Duo",
            "  2) \(simDuo.udid)  Sim Duo  [simulator]",
        ])
    }

    @Test func 問い合わせへの入力は_1からcountまでの整数だけを受ける() {
        #expect(parseChoice("1", count: 3) == 0)
        #expect(parseChoice("3", count: 3) == 2)
        #expect(parseChoice("  2 \n", count: 3) == 1)
        for bad in ["", " ", "0", "4", "-1", "+1", "1.5", "a", "q", "１", "99999999999999999999", "1 2"] {
            #expect(parseChoice(bad, count: 3) == nil, "\(bad)")
        }
        #expect(parseChoice("1", count: 0) == nil)
    }

    // MARK: - 対話式の問い合わせ(入出力を差し替えて検証)

    /// `inputs` を順に返し、尽きたら EOF(nil)を返す。表示は `output` に溜める。
    private func prompt(_ candidates: [DeviceEntry], inputs: [String]) -> (result: Result<DeviceEntry, CLIError>, output: String) {
        var rest = inputs[...]
        var output = ""
        do {
            let chosen = try promptForDevice(candidates, input: { rest.popFirst() }, output: { output += $0 })
            return (.success(chosen), output)
        } catch let error as CLIError {
            return (.failure(error), output)
        } catch {
            Issue.record("予期しないエラー: \(error)")
            return (.failure(CLIError("unexpected")), output)
        }
    }

    @Test func 番号を入力すればその候補が選ばれ_表示は候補とプロンプト() {
        let (result, output) = prompt([duo, simDuo], inputs: ["2"])
        #expect((try? result.get()) == simDuo)
        #expect(output == """
            Several connected devices support the hinge:
              1) \(duo.udid)  Test Duo
              2) \(simDuo.udid)  Sim Duo  [simulator]
            Select a device [1-2] (q to cancel): 
            """)
        #expect((try? prompt([duo, simDuo], inputs: [" 1 "]).result.get()) == duo)
    }

    @Test func 不正な入力は再度尋ね_有効な入力で選ばれる() {
        let (result, output) = prompt([duo, simDuo], inputs: ["", "x", "0", "3", "2"])
        #expect((try? result.get()) == simDuo)
        #expect(output.components(separatedBy: "Enter a number from 1 to 2, or q to cancel.\n").count - 1 == 4)
        #expect(output.components(separatedBy: "Select a device [1-2] (q to cancel): ").count - 1 == 5)
    }

    @Test func qで中止し_そのあとの入力は読まない() {
        // `q` のあとに有効な番号が続いても選ばれない(「不正な入力」ではなく、中止として扱う)
        for inputs in [["q", "1"], ["Q", "1"], [" q ", "1"], ["x", "q", "1"]] {
            let (result, output) = prompt([duo, simDuo], inputs: inputs)
            guard case .failure(let error) = result else { Issue.record("中止になるはず: \(inputs)"); continue }
            #expect(error.description == "No device was selected", "\(inputs)")
            #expect(output.components(separatedBy: "Enter a number").count - 1 == (inputs.first == "x" ? 1 : 0), "\(inputs)")
        }
    }

    @Test func 入力の終わりは中止() {
        for inputs in [[], ["x"]] {
            let (result, output) = prompt([duo, simDuo], inputs: inputs)
            guard case .failure(let error) = result else { Issue.record("中止になるはず: \(inputs)"); continue }
            #expect(error.description == "No device was selected", "\(inputs)")
            #expect(output.hasSuffix("\n"), "EOF のあと、プロンプトの行を閉じる")
        }
    }
}

