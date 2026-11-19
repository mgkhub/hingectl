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

@Suite("CoreDevice の JSON と実機の選択")
struct DevicesTests {
    // MARK: - CoreDeviceInfoRecord の解析

    private func makeCoreDevicePlistJSON(
        identifier: String = "11111111-2222-3333-4444-555555555555",
        name: String? = "iPhone Duo",
        udid: String? = "00000000-DUO0000000000001",
        serialNumber: String? = nil,
        reality: String = "physical",
        state: String = "connected",
        transportType: String? = "wired",
        bootState: String? = nil,
        platform: String? = "iOS",
        deviceType: String? = "iPhone",
        osVersion: String? = "27.1",
        osBuild: String? = "24A94425"
    ) -> Data {
        var values: [[String: Any]] = []

        func add(_ key: String, _ val: Any) {
            values.append([
                "descriptorIdentifier": ["key": key],
                "value": val
            ])
        }

        if let name { add("name", name) }
        if let udid { add("udid", udid) }
        if let serialNumber { add("serialNumber", serialNumber) }
        add("reality", reality)
        add("state", state)
        if let transportType { add("transportType", transportType) }
        if let bootState { add("bootState", bootState) }
        if let platform { add("platform", platform) }
        if let deviceType { add("deviceType", deviceType) }
        if let osVersion {
            add("osVersionNumber", ["stringValue": osVersion])
        }
        if let osBuild {
            add("osBuildVersions", ["buildVersion": ["name": osBuild]])
        }

        let dict: [String: Any] = [
            "identifier": identifier,
            "values": values
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func CoreDeviceのプロパティリストから実機のエントリを復元する() throws {
        let json = makeCoreDevicePlistJSON()
        let entry = try #require(decodeCoreDeviceRecord(data: json))

        #expect(entry.id == "11111111-2222-3333-4444-555555555555")
        #expect(entry.name == "iPhone Duo")
        #expect(entry.udid == "00000000-DUO0000000000001")
        #expect(entry.connectionState == .connected)
        #expect(entry.reality == .physical)
        #expect(entry.transport == "wired")
        #expect(entry.osName == "iOS")
        #expect(entry.osVersion == "27.1")
        #expect(entry.osBuild == "24A94425")
        #expect(entry.osText == "iOS 27.1")
        #expect(!entry.mayHaveHinge)
    }

    @Test func capabilitiesを渡すとDeviceEntryに反映されmayHaveHingeが有効になる() throws {
        let json = makeCoreDevicePlistJSON(state: "disconnected")
        let entry = try #require(decodeCoreDeviceRecord(data: json, capabilities: [DeviceEntry.orientationControlFeature]))

        #expect(entry.connectionState == .disconnected)
        #expect(entry.isWakeable)
        #expect(entry.mayHaveHinge)
        #expect(entry.capabilities.contains(DeviceEntry.orientationControlFeature))
    }

    @Test func udidが欠落していてserialNumberがある場合はフォールバックする() throws {
        let json = makeCoreDevicePlistJSON(udid: nil, serialNumber: "SERIAL12345")
        let entry = try #require(decodeCoreDeviceRecord(data: json))
        #expect(entry.udid == "SERIAL12345")
    }

    @Test func iPadの場合はosNameがiPadOSになる() throws {
        let json = makeCoreDevicePlistJSON(name: "iPad mini", platform: "iOS", deviceType: "iPad")
        let entry = try #require(decodeCoreDeviceRecord(data: json))
        #expect(entry.osName == "iPadOS")
        #expect(entry.osText == "iPadOS 27.1")
    }

    @Test func シミュレータは起動中かつ接続中のみエントリになりそれ以外はnil() throws {
        // 起動中 & 接続中
        let bootedJSON = makeCoreDevicePlistJSON(reality: "simulated", state: "connected", bootState: "booted")
        let bootedEntry = decodeCoreDeviceRecord(data: bootedJSON)
        #expect(bootedEntry != nil)
        #expect(bootedEntry?.isSimulator == true)

        // 停止中
        let shutdownJSON = makeCoreDevicePlistJSON(reality: "simulated", state: "connected", bootState: "shutdown")
        #expect(decodeCoreDeviceRecord(data: shutdownJSON) == nil)

        // 切断中
        let disconnectedJSON = makeCoreDevicePlistJSON(reality: "simulated", state: "disconnected", bootState: "booted")
        #expect(decodeCoreDeviceRecord(data: disconnectedJSON) == nil)

        // bootState 欠落
        let noBootStateJSON = makeCoreDevicePlistJSON(reality: "simulated", state: "connected", bootState: nil)
        #expect(decodeCoreDeviceRecord(data: noBootStateJSON) == nil)

        // state 欠落
        let noStateJSON = try JSONSerialization.data(withJSONObject: [
            "identifier": "S-NO-STATE",
            "values": [
                ["descriptorIdentifier": ["key": "reality"], "value": "simulated"],
                ["descriptorIdentifier": ["key": "bootState"], "value": "booted"],
            ]
        ])
        #expect(decodeCoreDeviceRecord(data: noStateJSON) == nil)
    }

    @Test func 不正なJSONや必須フィールド欠損時は安全にnilを返す() {
        #expect(decodeCoreDeviceRecord(data: Data()) == nil)
        #expect(decodeCoreDeviceRecord(data: Data("{}".utf8)) == nil)

        // identifier 欠落
        let noID = try! JSONSerialization.data(withJSONObject: ["values": []])
        #expect(decodeCoreDeviceRecord(data: noID) == nil)

        // reality 欠落
        let noReality = try! JSONSerialization.data(withJSONObject: [
            "identifier": "ABC",
            "values": [["descriptorIdentifier": ["key": "name"], "value": "Test"]]
        ])
        #expect(decodeCoreDeviceRecord(data: noReality) == nil)

        // 未知の reality
        let otherReality = makeCoreDevicePlistJSON(identifier: "X1", name: "Other", udid: "UX", reality: "other", state: "connected")
        #expect(decodeCoreDeviceRecord(data: otherReality) == nil)
    }

    // MARK: - 一覧・デコードの寛容性と表示

    @Test func OSの情報が無い_または型が違えば_nilになり_ほかの項目は読める() throws {
        let noOS = makeCoreDevicePlistJSON(identifier: "P1", name: "Watch", udid: "U1", platform: "watchOS", deviceType: nil, osVersion: nil, osBuild: nil)
        let watch = try #require(decodeCoreDeviceRecord(data: noOS))
        #expect(watch.name == "Watch")
        #expect(watch.osName == "watchOS")
        #expect(watch.osVersion == nil)
        #expect(watch.osText == nil)

        let wrongTypes = try JSONSerialization.data(withJSONObject: [
            "identifier": "P2",
            "values": [
                ["descriptorIdentifier": ["key": "name"], "value": "X"],
                ["descriptorIdentifier": ["key": "reality"], "value": "physical"],
                ["descriptorIdentifier": ["key": "udid"], "value": "U2"],
                ["descriptorIdentifier": ["key": "osVersionNumber"], "value": 27],
                ["descriptorIdentifier": ["key": "osBuildVersions"], "value": false],
                ["descriptorIdentifier": ["key": "platform"], "value": 7],
                ["descriptorIdentifier": ["key": "deviceType"], "value": []],
            ]
        ])
        let x = try #require(decodeCoreDeviceRecord(data: wrongTypes))
        #expect(x.name == "X")
        #expect(x.osName == nil)
        #expect(x.osVersion == nil)
        #expect(x.osBuild == nil)
        #expect(x.osText == nil)
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

    @Test func 欠けた項目は既定値で補う() throws {
        let minimal = try JSONSerialization.data(withJSONObject: [
            "identifier": "P2",
            "values": [["descriptorIdentifier": ["key": "reality"], "value": "physical"]]
        ])
        #expect(decodeCoreDeviceRecord(data: minimal) == DeviceEntry(id: "P2", name: "(unnamed)", udid: "P2", connectionState: "unknown"))
    }

    @Test func 型の違う項目だけが既定値に落ち_未知のキーは無視される() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": "P3",
            "extra": ["a": [1, 2]],
            "values": [
                ["descriptorIdentifier": ["key": "name"], "value": 7],
                ["descriptorIdentifier": ["key": "other"], "value": true],
                ["descriptorIdentifier": ["key": "reality"], "value": "physical"],
                ["descriptorIdentifier": ["key": "udid"], "value": ["x"]],
                ["descriptorIdentifier": ["key": "state"], "value": false],
                ["descriptorIdentifier": "broken", "value": "ignored"],
            ]
        ])
        #expect(decodeCoreDeviceRecord(data: data) == DeviceEntry(id: "P3", name: "(unnamed)", udid: "P3", connectionState: "unknown"))

        // values 自体が配列でない場合も、クラッシュせず nil になる
        let nonArrayValues = try JSONSerialization.data(withJSONObject: [
            "identifier": "P4",
            "values": "x"
        ])
        #expect(decodeCoreDeviceRecord(data: nonArrayValues) == nil)
    }

    @Test func 配列の壊れた要素だけが除外される() throws {
        let data = Data(#"""
            {"identifier":"P5","values":[1,"x",null,[],
              {"descriptorIdentifier":{"key":"name"},"value":"Ok"},
              {"descriptorIdentifier":{"key":"reality"},"value":"physical"},
              {"descriptorIdentifier":{"key":"udid"},"value":"U5"},
              {"descriptorIdentifier":{"key":"state"},"value":"connected"}]}
            """#.utf8)
        #expect(decodeCoreDeviceRecord(data: data) == DeviceEntry(id: "P5", name: "Ok", udid: "U5", connectionState: "connected"))
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

    @Test func 判定できなかった端末は_エラーに添える() async throws {
        let message: String?
        do {
            // 重複して判定不能として報告されても、1 台につき 1 行だけ示す
            _ = try await selectDevice(from: [phone, simDuo], query: nil, narrowByCapability: { _ in [] }, undetermined: { [phone, away, phone] })
            message = nil
        } catch let error as CLIError { message = error.description }
        // 接続中の候補に含まれる端末だけを示す
        #expect(message == """
            No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:
              \(phone.udid)  Test Phone
              \(simDuo.udid)  Sim Duo  [simulator]
            Could not determine whether these support the hinge (they may, if the failure was temporary; try again):
              \(phone.udid)  Test Phone
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

    @Test func 暗黙の選択の通知は名前と種類とUDIDを含む() {
        let real = DeviceEntry(id: "P1", name: "iPhone Duo", udid: "00008160-AAAA", connectionState: "connected")
        let sim = DeviceEntry(id: "S1", name: "iPhone Duo", udid: "S1-UDID", connectionState: "connected", reality: .simulated)
        #expect(implicitSelectionNote(real).contains("physical device"))
        #expect(implicitSelectionNote(real).contains("00008160-AAAA"))
        #expect(implicitSelectionNote(sim).contains("simulator"))
        #expect(implicitSelectionNote(sim).contains("pass -d"))
    }
}

