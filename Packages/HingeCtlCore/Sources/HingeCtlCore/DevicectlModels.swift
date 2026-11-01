import Foundation

// `devicectl ... -q -j -` の JSON を読むための、Decodable の DTO(このモジュールの内部用)。
// ドメインの型(DeviceEntry / DisplayState)へは、Devices.swift / Displays.swift の公開関数が変換する。
//
// 読み方は「寛容」にしている: 型が違う・欠けた・null の項目は nil にして、既定値はドメイン型への変換で補う。
// 未知のキーは無視する。配列は、壊れた要素だけを除外して、ほかを読む。

/// 中身を読み捨てる(キーの有無だけを見たいときに使う。`{"integrated": {}}` など)
struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 壊れた要素があっても、配列全体を失敗させないためのラッパー。
/// `UnkeyedDecodingContainer` の手書きループは、失敗した要素でインデックスが進まず無限ループになるため、
/// 要素ごとに「決して throw しない」デコードをするこの型で包む。
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// 型の不一致・欠落・null をすべて nil にして読む
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }
}

// MARK: - 応答の封筒

/// `{"info": {"outcome": "success", ...}, "result": {...}}`
struct DevicectlEnvelope<Result: Decodable>: Decodable {
    let outcome: String?
    let result: Result?

    private enum CodingKeys: String, CodingKey { case info, result }

    private struct Info: Decodable {
        let outcome: String?
        private enum CodingKeys: String, CodingKey { case outcome }
        init(from decoder: Decoder) throws {
            outcome = try decoder.container(keyedBy: CodingKeys.self).lenient(String.self, forKey: .outcome)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = container.lenient(Info.self, forKey: .info)?.outcome
        result = container.lenient(Result.self, forKey: .result)
    }
}

/// `outcome` が success で `result` が読めるときだけ `result` を返す。
/// それ以外(JSON でない、失敗、`result` が無い・オブジェクトでない)は、`stderr` を添えて CLIError を投げる。
func decodeDevicectl<Result: Decodable>(_ type: Result.Type, stdout: Data, stderr: String, label: String) throws -> Result {
    guard let envelope = try? JSONDecoder().decode(DevicectlEnvelope<Result>.self, from: stdout),
          envelope.outcome == "success", let result = envelope.result else {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CLIError("devicectl \(label) failed\(detail.isEmpty ? "" : ": \(detail)")")
    }
    return result
}

// MARK: - devicectl list devices

struct DeviceRecord: Decodable {
    let identifier: String?
    let name: String?
    let udid: String?
    let reality: String?
    let tunnelState: String?
    let transportType: String?
    let capabilities: Set<String>
    let osVersion: String?
    let osBuild: String?
    let platform: String?
    let deviceType: String?

    private enum CodingKeys: String, CodingKey { case identifier, deviceProperties, hardwareProperties, connectionProperties, capabilities }

    private struct Capability: Decodable {
        let featureIdentifier: String?
        private enum CodingKeys: String, CodingKey { case featureIdentifier }
        init(from decoder: Decoder) throws {
            featureIdentifier = try decoder.container(keyedBy: CodingKeys.self).lenient(String.self, forKey: .featureIdentifier)
        }
    }

    private struct Properties: Decodable {
        let name: String?
        /// OS のバージョン(例: `27.1`)とビルド(例: `24A94425`)。切断中の実機の一覧にも載る。Apple Watch などには無い
        let osVersionNumber: String?
        let osBuildUpdate: String?
        private enum CodingKeys: String, CodingKey { case name, osVersionNumber, osBuildUpdate }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.lenient(String.self, forKey: .name)
            osVersionNumber = container.lenient(String.self, forKey: .osVersionNumber)
            osBuildUpdate = container.lenient(String.self, forKey: .osBuildUpdate)
        }
    }

    private struct Hardware: Decodable {
        let reality: String?
        let udid: String?
        /// `iOS` / `watchOS` など。iPad も `iOS` と報告されるため、OS の名前は `deviceType` と合わせて決める
        let platform: String?
        let deviceType: String?
        private enum CodingKeys: String, CodingKey { case reality, udid, platform, deviceType }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reality = container.lenient(String.self, forKey: .reality)
            udid = container.lenient(String.self, forKey: .udid)
            platform = container.lenient(String.self, forKey: .platform)
            deviceType = container.lenient(String.self, forKey: .deviceType)
        }
    }

    private struct Connection: Decodable {
        let tunnelState: String?
        /// 経路。つながらない(`unavailable`)デバイスには、キー自体が無い
        let transportType: String?
        private enum CodingKeys: String, CodingKey { case tunnelState, transportType }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tunnelState = container.lenient(String.self, forKey: .tunnelState)
            transportType = container.lenient(String.self, forKey: .transportType)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = container.lenient(String.self, forKey: .identifier)
        let properties = container.lenient(Properties.self, forKey: .deviceProperties)
        name = properties?.name
        osVersion = properties?.osVersionNumber
        osBuild = properties?.osBuildUpdate
        let hardware = container.lenient(Hardware.self, forKey: .hardwareProperties)
        reality = hardware?.reality
        udid = hardware?.udid
        platform = hardware?.platform
        deviceType = hardware?.deviceType
        let connection = container.lenient(Connection.self, forKey: .connectionProperties)
        tunnelState = connection?.tunnelState
        transportType = connection?.transportType
        capabilities = Set((container.lenient([Capability].self, forKey: .capabilities) ?? []).compactMap(\.featureIdentifier))
    }

    /// 実機と、起動中(接続中)のシミュレータで、識別子があるものだけ。それ以外は nil。
    var entry: DeviceEntry? {
        guard let identifier, let reality = reality.flatMap(DeviceReality.init(rawValue:)) else { return nil }
        let state = ConnectionState(tunnelState ?? "unknown")
        if reality == .simulated && state != .connected { return nil }
        return DeviceEntry(id: identifier, name: name ?? "(unnamed)", udid: udid ?? identifier,
                           connectionState: state, reality: reality, transport: transportType,
                           capabilities: capabilities, osName: osDisplayName(platform: platform, deviceType: deviceType),
                           osVersion: osVersion, osBuild: osBuild)
    }
}

struct DeviceList: Decodable {
    let devices: [DeviceRecord]

    private enum CodingKeys: String, CodingKey { case devices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = (container.lenient([Lossy<DeviceRecord>].self, forKey: .devices) ?? []).compactMap(\.value)
    }
}

// MARK: - devicectl device info displays

struct DisplayRecord: Decodable {
    let name: String?
    let uniqueId: String?
    let displayId: Int?
    let primary: Bool?
    let active: Bool?
    let backlightState: String?
    let currentOrientation: String?
    let nativeSize: [Int]?
    let pointScale: Int?
    /// `{"integrated": {}}` のように、種別がキーになっている。値は読まず、キーの有無だけを見る。
    let type: [String: Ignored]?

    private enum CodingKeys: String, CodingKey {
        case name, uniqueId, displayId, primary, active, backlightState, currentOrientation, nativeSize, pointScale, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenient(String.self, forKey: .name)
        uniqueId = container.lenient(String.self, forKey: .uniqueId)
        displayId = container.lenient(Int.self, forKey: .displayId)
        primary = container.lenient(Bool.self, forKey: .primary)
        active = container.lenient(Bool.self, forKey: .active)
        backlightState = container.lenient(String.self, forKey: .backlightState)
        currentOrientation = container.lenient(String.self, forKey: .currentOrientation)
        nativeSize = container.lenient([Int].self, forKey: .nativeSize)
        pointScale = container.lenient(Int.self, forKey: .pointScale)
        type = container.lenient([String: Ignored].self, forKey: .type)
    }

    /// 内蔵(integrated)ディスプレイだけ。それ以外は nil。
    var state: DisplayState? {
        guard let type, type["integrated"] != nil else { return nil }
        let backlight = Backlight(backlightState ?? "unknown")
        return DisplayState(
            name: name ?? "(unnamed)",
            uniqueId: uniqueId ?? "",
            displayId: displayId,
            primary: primary ?? false,
            active: active ?? backlight.isLit,
            backlight: backlight,
            rotation: currentOrientation ?? "unknown",
            width: nativeSize?.first,
            height: (nativeSize?.count ?? 0) > 1 ? nativeSize?[1] : nil,
            scale: pointScale)
    }
}

struct DisplayList: Decodable {
    let displays: [DisplayRecord]

    private enum CodingKeys: String, CodingKey { case displays }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displays = (container.lenient([Lossy<DisplayRecord>].self, forKey: .displays) ?? []).compactMap(\.value)
    }
}

/// OS の表示名。`platform` は iPad でも `iOS` と報告されるため、`deviceType` が `iPad` なら `iPadOS` にする。
func osDisplayName(platform: String?, deviceType: String?) -> String? {
    guard let platform else { return nil }
    return platform == "iOS" && deviceType == "iPad" ? "iPadOS" : platform
}
