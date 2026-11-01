import Foundation
import Testing
@testable import HingeCtlCore

// `--json` の出力は、バイト列で完全一致を確認する(1 行・キー辞書順、値が無い項目は null)。
// 期待値のうち posture は、実機で取った出力と同じ形(UDID・名前だけ架空)。

private func state(_ name: String, id: Int?, primary: Bool, active: Bool, backlight: Backlight,
                   rotation: String, width: Int?, height: Int?, scale: Int?) -> DisplayState {
    DisplayState(name: name, uniqueId: "", displayId: id, primary: primary, active: active, backlight: backlight,
                 rotation: rotation, width: width, height: height, scale: scale)
}

@Suite("--json の出力")
struct JSONOutputTests {
    // MARK: - 単純な出力

    @Test func 角度() {
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 180, sensorAngle: 180)) == #"{"mechanicalAngle":180,"sensorAngle":180}"#)     // 整数の Double は小数点なし
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 0, sensorAngle: 0)) == #"{"mechanicalAngle":0,"sensorAngle":0}"#)
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 90.5, sensorAngle: 90.5)) == #"{"mechanicalAngle":90.5,"sensorAngle":90.5}"#)
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 90, sensorAngle: 94.6)) == #"{"mechanicalAngle":90,"sensorAngle":94.6}"#)
    }

    @Test func 小数は最短の表記になる() {
        // 以前の JSONSerialization は 119.95999999999999 と出していた。値は同じ Double
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 119.96, sensorAngle: 120)) == #"{"mechanicalAngle":119.96,"sensorAngle":120}"#)
        #expect(encodeJSON(AngleOutput(mechanicalAngle: 141.8, sensorAngle: 141.8)) == #"{"mechanicalAngle":141.8,"sensorAngle":141.8}"#)
        let text = encodeJSON(AngleOutput(mechanicalAngle: 119.96, sensorAngle: 120)) ?? ""
        let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(decoded?["mechanicalAngle"] as? Double == 119.96)
        #expect(decoded?["sensorAngle"] as? Double == 120)
    }

    @Test func 向きが無いときはunknown() {
        #expect(encodeJSON(OrientationOutput(orientation: nil)) == #"{"orientation":"unknown"}"#)
        let posture = PostureOutput(udid: "U", name: "N", mechanicalAngle: nil, orientation: .unknown, displays: [], active: nil)
        #expect(encodeJSON(posture) == #"{"activeDisplay":null,"device":{"name":"N","udid":"U"},"displays":[],"mechanicalAngle":null,"orientation":"unknown","sensorAngle":null}"#)
    }

    @Test func 向き() {
        #expect(encodeJSON(OrientationOutput(orientation: .portrait)) == #"{"orientation":"portrait"}"#)
    }

    @Test func スクリーンショットのパスはスラッシュがエスケープされる() {
        #expect(encodeJSON(ScreenshotOutput(display: "LCD-1", path: "/Users/x/a b.png")) == #"{"display":"LCD-1","path":"\/Users\/x\/a b.png"}"#)
    }

    @Test func 日本語と引用符() {
        #expect(encodeJSON(ScreenshotOutput(display: "背面", path: #"a"b"#)) == #"{"display":"背面","path":"a\"b"}"#)
    }

    @Test func watchはキー辞書順() {
        let reading = HingeReading(mechanicalAngle: 90.5, sensorAngle: 90.5, isValid: true, minAngle: 0, maxAngle: 180, timestamp: 1000.25)
        #expect(encodeJSON(reading) == #"{"max":180,"mechanicalAngle":90.5,"min":0,"sensorAngle":90.5,"timestamp":1000.25,"valid":true}"#)
    }

    // MARK: - list

    @Test func 一覧はstateキーに接続状態を出し_realityで実機とシミュレータを区別する() {
        let devices = [DeviceEntry(id: "P1", name: "Real", udid: "U1", connectionState: "connected"),
                       DeviceEntry(id: "P2", name: "日本語", udid: "U2", connectionState: "unavailable"),
                       DeviceEntry(id: "S1", name: "Sim", udid: "S1", connectionState: "connected", reality: .simulated)]
        #expect(encodeJSON(devices) == #"[{"id":"P1","name":"Real","reality":"physical","state":"connected","udid":"U1"},{"id":"P2","name":"日本語","reality":"physical","state":"unavailable","udid":"U2"},{"id":"S1","name":"Sim","reality":"simulated","state":"connected","udid":"S1"}]"#)
        #expect(encodeJSON([DeviceEntry]()) == "[]")
    }

    // MARK: - posture

    private let foldedOpen = [
        state("LCD", id: 1, primary: true, active: false, backlight: "off", rotation: "rot0", width: 1398, height: 2034, scale: 3),
        state("LCD-1", id: 2, primary: false, active: true, backlight: "activeOn", rotation: "rot90", width: 1878, height: 2670, scale: 3),
    ]

    @Test func postureは実機の出力と同じ形() {
        let output = PostureOutput(udid: "U-1", name: "Test Duo", mechanicalAngle: 180, orientation: .known(.portrait), displays: foldedOpen, active: 1)
        #expect(encodeJSON(output) == #"{"activeDisplay":"LCD-1","device":{"name":"Test Duo","udid":"U-1"},"displays":[{"active":false,"backlight":"off","id":1,"name":"LCD","primary":true,"rotation":"rot0","scale":3,"size":[1398,2034]},{"active":true,"backlight":"activeOn","id":2,"name":"LCD-1","primary":false,"rotation":"rot90","scale":3,"size":[1878,2670]}],"mechanicalAngle":180,"orientation":"portrait","sensorAngle":null}"#)
    }

    @Test func ヒンジ非対応のデバイスの_角度と向きが読めないposture() {
        let output = PostureOutput(udid: "U", name: "N", mechanicalAngle: nil, orientation: .unavailable, displays: [], active: nil)
        #expect(encodeJSON(output) == #"{"activeDisplay":null,"device":{"name":"N","udid":"U"},"displays":[],"mechanicalAngle":null,"orientation":null,"sensorAngle":null}"#)
    }

    @Test func 値が無い項目はnullで出る() {
        let output = PostureOutput(udid: "U", name: "N", mechanicalAngle: nil, orientation: .known(.portrait), displays: [], active: nil)
        #expect(encodeJSON(output) == #"{"activeDisplay":null,"device":{"name":"N","udid":"U"},"displays":[],"mechanicalAngle":null,"orientation":"portrait","sensorAngle":null}"#)

        let sparse = [state("A", id: nil, primary: false, active: false, backlight: "unknown", rotation: "unknown", width: nil, height: nil, scale: nil)]
        let text = encodeJSON(PostureOutput(udid: "U", name: "N", mechanicalAngle: 90, orientation: .known(.portrait), displays: sparse, active: nil)) ?? ""
        #expect(text.contains(#""id":null"#))
        #expect(text.contains(#""scale":null"#))
        #expect(text.contains(#""size":[null,null]"#))
        #expect(text.contains(#""activeDisplay":null"#))
    }

    @Test func 幅だけ_高さだけが無いときも要素ごとにnull() {
        let onlyWidth = [state("A", id: 1, primary: false, active: true, backlight: "activeOn", rotation: "rot0", width: 100, height: nil, scale: 1)]
        let text = encodeJSON(PostureOutput(udid: "U", name: "N", mechanicalAngle: 1, orientation: .known(.portrait), displays: onlyWidth, active: 0)) ?? ""
        #expect(text.contains(#""size":[100,null]"#))
    }

    @Test func 出力のキー集合は固定() throws {
        let text = try #require(encodeJSON(PostureOutput(udid: "U", name: "N", mechanicalAngle: 1, orientation: .known(.portrait), displays: foldedOpen, active: 0)))
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["device", "mechanicalAngle", "sensorAngle", "orientation", "activeDisplay", "displays"])
        let first = try #require((object["displays"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["name", "id", "primary", "active", "backlight", "rotation", "size", "scale"])
    }

    // MARK: - 読み書きの往復

    @Test func デコードした実機の応答から_出力まで通る() throws {
        let response = Data(#"""
            {"info":{"outcome":"success"},"result":{"displays":[
              {"name":"LCD","displayId":1,"uniqueId":"c","primary":true,"active":false,"backlightState":"off",
               "currentOrientation":"rot0","nativeSize":[1398,2034],"pointScale":3,"type":{"integrated":{}}},
              {"name":"LCD-1","displayId":2,"uniqueId":"i","primary":false,"active":true,"backlightState":"activeOn",
               "currentOrientation":"rot90","nativeSize":[1878,2670],"pointScale":3,"type":{"integrated":{}}}]}}
            """#.utf8)
        let (displays, active) = try decodeDisplays(stdout: response, stderr: "", label: "device info displays")
        let output = PostureOutput(udid: "U-1", name: "Test Duo", mechanicalAngle: 180, orientation: .known(.portrait), displays: displays, active: active)
        #expect(encodeJSON(output) == encodeJSON(PostureOutput(udid: "U-1", name: "Test Duo", mechanicalAngle: 180, orientation: .known(.portrait), displays: foldedOpen, active: 1)))
    }
}
