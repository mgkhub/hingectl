import Foundation
import Testing
@testable import HingeCtlCore

// フィクスチャは `devicectl device info displays -q -j -` の応答に近い JSON 文字列(ID は架空)。

private func display(_ name: String, id: Int, uniqueId: String, primary: Bool = false,
                     active: Bool? = nil, backlight: String? = nil,
                     size: String = "[100,200]", rotation: String = "rot0", type: String = #"{"integrated":{}}"#) -> String {
    var fields = [
        #""name":"\#(name)""#, #""displayId":\#(id)"#, #""uniqueId":"\#(uniqueId)""#, #""primary":\#(primary)"#,
        #""currentOrientation":"\#(rotation)""#, #""nativeSize":\#(size)"#, #""pointScale":3"#, #""type":\#(type)"#,
    ]
    if let active { fields.append(#""active":\#(active)"#) }
    if let backlight { fields.append(#""backlightState":"\#(backlight)""#) }
    return "{" + fields.joined(separator: ",") + "}"
}

private func response(_ displays: [String]) -> Data {
    Data(#"{"info":{"outcome":"success"},"result":{"displays":[\#(displays.joined(separator: ","))]}}"#.utf8)
}

private func decode(_ displays: [String]) throws -> (displays: [DisplayState], active: Int?) {
    try decodeDisplays(stdout: response(displays), stderr: "", label: "device info displays")
}

/// 折りたたみ(Duo)の例: 背面は消灯、内側が active。ほかに wireless ディスプレイ(内蔵ではない)が並ぶ。
private let foldedOpen = [
    display("LCD", id: 1, uniqueId: "cover", primary: true, active: false, backlight: "off", size: "[1398,2034]"),
    display("LCD-1", id: 2, uniqueId: "inner", active: true, backlight: "activeOn", size: "[1878,2670]", rotation: "rot90"),
    #"{"name":"Wireless","displayId":4,"uniqueId":"w","type":{"wireless":{}}}"#,
]

@Suite("ディスプレイの解析と posture の出力")
struct DisplaysTests {
    // MARK: - 解析

    @Test func 内蔵ディスプレイだけを読みactiveの添字を返す() throws {
        let (displays, active) = try decode(foldedOpen)
        #expect(displays.map(\.name) == ["LCD", "LCD-1"])
        #expect(active == 1)
        #expect(displays[0].primary)
        #expect(displays[1].rotation == "rot90")
        #expect(displays[1].width == 1878 && displays[1].height == 2670 && displays[1].scale == 3)
        #expect(displays[1].displayId == 2 && displays[1].uniqueId == "inner")
    }

    @Test func 折りたたむとactiveが背面に移る() throws {
        let (_, active) = try decode([
            display("LCD", id: 1, uniqueId: "cover", primary: true, active: true, backlight: "activeOn"),
            display("LCD-1", id: 2, uniqueId: "inner", active: false, backlight: "activeOn"),   // 内側はしばらく点いたまま
        ])
        #expect(active == 0)
    }

    @Test func activeを返さない場合はバックライトの点灯で代用する() throws {
        let (displays, active) = try decode([
            display("A", id: 1, uniqueId: "a", backlight: "off"),
            display("B", id: 2, uniqueId: "b", backlight: "activeOn"),
        ])
        #expect(displays.map(\.active) == [false, true])
        #expect(active == 1)
    }

    @Test func バックライトも不明なら消灯扱い() throws {
        let (displays, active) = try decode([display("A", id: 1, uniqueId: "a"), display("B", id: 2, uniqueId: "b")])
        #expect(displays.map(\.active) == [false, false])
        #expect(active == nil)
    }

    @Test func ディスプレイが1つなら_何も返さなくてもそれが使われる() throws {
        let (displays, active) = try decode([display("LCD", id: 1, uniqueId: "only")])
        #expect(active == 0)
        #expect(displays[0].active)
    }

    @Test func 内蔵ディスプレイがなければエラー() {
        #expect(throws: CLIError.self) { try decode([]) }
        #expect(throws: CLIError.self) { try decode([#"{"name":"Wireless","type":{"wireless":{}}}"#]) }
    }

    @Test func バックライトの点灯判定() {
        func state(_ backlight: Backlight) -> DisplayState {
            DisplayState(name: "x", uniqueId: "", displayId: nil, primary: false, active: true, backlight: backlight,
                         rotation: "rot0", width: nil, height: nil, scale: nil)
        }
        #expect(state("activeOn").isLit)
        #expect(state("dim").isLit)
        #expect(!state("off").isLit)
        #expect(!state("unknown").isLit)
    }

    // MARK: - 寛容なデコード

    @Test func 型の違う項目だけが既定値に落ちる() throws {
        let broken = #"""
            {"name":42,"uniqueId":["x"],"displayId":"2","primary":"yes","active":true,"backlightState":5,
             "currentOrientation":null,"nativeSize":[1.5,2.5],"pointScale":"3","type":{"integrated":{}}}
            """#
        let (displays, _) = try decode([broken])
        let d = displays[0]
        #expect(d.name == "(unnamed)" && d.uniqueId == "" && d.displayId == nil && !d.primary)
        #expect(d.backlight == "unknown" && d.rotation == "unknown")
        #expect(d.width == nil && d.height == nil && d.scale == nil)
        #expect(d.active)
    }

    @Test func 未知のキーと追加のキーは無視される() throws {
        let extra = #"""
            {"name":"LCD","type":{"integrated":{"extra":[1,2,3]}},"bounds":[[0,0],[1,2]],"physicalSize":[3.03,4.42],
             "future":{"nested":true},"active":true,"backlightState":"activeOn"}
            """#
        let (displays, active) = try decode([extra])
        #expect(displays.map(\.name) == ["LCD"] && active == 0)
    }

    @Test func 配列の壊れた要素だけが除外される() throws {
        let data = Data(#"""
            {"info":{"outcome":"success"},"result":{"displays":[1,"x",null,[],
              {"name":"OK","type":{"integrated":{}},"active":true,"backlightState":"activeOn"}]}}
            """#.utf8)
        let (displays, _) = try decodeDisplays(stdout: data, stderr: "", label: "device info displays")
        #expect(displays.map(\.name) == ["OK"])
    }

    @Test func 種別の値がnullでも_キーがあれば内蔵として扱う() throws {
        let (displays, _) = try decode([#"{"name":"A","type":{"integrated":null},"active":true}"#])
        #expect(displays.map(\.name) == ["A"])
    }

    @Test func 種別が無い_または辞書でないものは除外() {
        #expect(throws: CLIError.self) { try decode([#"{"name":"A","active":true}"#]) }
        #expect(throws: CLIError.self) { try decode([#"{"name":"A","type":"integrated","active":true}"#]) }
    }

    @Test func 整数として読める小数は整数として読む() throws {
        let (displays, _) = try decode([#"{"name":"A","type":{"integrated":{}},"nativeSize":[1398.0,2034.0],"displayId":2.0,"pointScale":3.0}"#])
        #expect(displays[0].width == 1398 && displays[0].height == 2034 && displays[0].displayId == 2 && displays[0].scale == 3)
    }

    // MARK: - 応答の封筒

    @Test func outcomeが成功でない_JSONでない_resultが無いときはエラー() {
        let cases: [(String, String, String)] = [
            (#"{"info":{"outcome":"failed"}}"#, "boom\n", "devicectl device info displays failed: boom"),
            (#"{"info":{"outcome":"failed"},"result":{}}"#, "", "devicectl device info displays failed"),
            ("not json", "", "devicectl device info displays failed"),
            (#"{"info":{"outcome":"success"}}"#, "", "devicectl device info displays failed"),
            (#"{"info":{"outcome":"success"},"result":[]}"#, "", "devicectl device info displays failed"),
            (#"{"result":{"displays":[]}}"#, "", "devicectl device info displays failed"),
        ]
        for (stdout, stderr, expected) in cases {
            do {
                _ = try decodeDisplays(stdout: Data(stdout.utf8), stderr: stderr, label: "device info displays")
                Issue.record("エラーになるはず: \(stdout)")
            } catch let error as CLIError {
                #expect(error.description == expected, "\(stdout)")
            } catch {
                Issue.record("予期しないエラー: \(error)")
            }
        }
    }

    // MARK: - posture の表示

    @Test func postureの表示() throws {
        let (displays, _) = try decode(foldedOpen)
        let lines = postureLines(udid: "U-1", name: "Test Duo", mechanicalAngle: 180, orientation: .known(.portrait), displays: displays)
        #expect(lines == [
            "device: Test Duo (U-1)",
            "angle: 180.0",
            "orientation: portrait",
            "display: LCD (primary) (backlight: off)",
            "display: LCD-1 (active) (backlight: activeOn)",
        ])
    }

    @Test func 向きが読めないときの表示() throws {
        let (displays, _) = try decode(foldedOpen)
        let lines = postureLines(udid: "U", name: "N", mechanicalAngle: nil, orientation: .unavailable, displays: displays)
        #expect(lines[1] == "angle: unavailable")
        #expect(lines[2] == "orientation: unavailable")
    }

    @Test func 角度が読めないときの表示() throws {
        let (displays, _) = try decode(foldedOpen)
        #expect(postureLines(udid: "U", name: "N", mechanicalAngle: nil, orientation: .known(.portrait), displays: displays)[1] == "angle: unavailable")
    }
}
