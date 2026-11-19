import Foundation

// CoreDevice の JSON を読むための、型安全な Decodable DTO。
// ドメインの型(DeviceEntry / DisplayState)へは、このモジュールの公開関数が変換する。
//
// 読み方は「寛容」にしている: 型が違う・欠けた・null の項目は nil にして、既定値はドメイン型への変換で補う。
// 未知のキーは無視する。配列は、壊れた要素だけを除外して、ほかを読む。

/// 中身を読み捨てる(キーの有無だけを見たいときに使う。`{"integrated": {}}` など)
struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 壊れた要素があっても、配列全体を失敗させないためのラッパー。
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

// MARK: - CoreDevice DeviceInfo (プロパティリスト形式)

/// `CoreDevice.RemoteDevice.deviceInfo` をエンコードしたプロパティリスト形式の JSON を型安全にデコードするレコード。
public struct CoreDeviceInfoRecord: Decodable {
    public let identifier: String?
    public let name: String?
    public let udid: String?
    public let reality: String?
    public let state: String?
    public let transportType: String?
    public let bootState: String?
    public let platform: String?
    public let deviceType: String?
    public let osVersion: String?
    public let osBuild: String?

    private enum CodingKeys: String, CodingKey {
        case identifier, values
    }

    private struct RawValue: Decodable {
        struct Descriptor: Decodable {
            let key: String?
        }
        let descriptorIdentifier: Descriptor?

        let stringValue: String?
        let boolValue: Bool?
        let osVersionValue: OSVersionNumber?
        let osBuildValue: OSBuildVersions?

        enum ItemKeys: String, CodingKey {
            case descriptorIdentifier, value
        }

        struct OSVersionNumber: Decodable {
            let stringValue: String?
        }

        struct OSBuildVersions: Decodable {
            struct BuildVersion: Decodable {
                let name: String?
            }
            let buildVersion: BuildVersion?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ItemKeys.self)
            descriptorIdentifier = try? container.decodeIfPresent(Descriptor.self, forKey: .descriptorIdentifier)
            stringValue = try? container.decodeIfPresent(String.self, forKey: .value)
            boolValue = try? container.decodeIfPresent(Bool.self, forKey: .value)
            osVersionValue = try? container.decodeIfPresent(OSVersionNumber.self, forKey: .value)
            osBuildValue = try? container.decodeIfPresent(OSBuildVersions.self, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        let rawValues = (try? container.decodeIfPresent([RawValue].self, forKey: .values)) ?? []

        var nameVal: String?
        var udidVal: String?
        var realityVal: String?
        var stateVal: String?
        var transportVal: String?
        var bootStateVal: String?
        var platformVal: String?
        var deviceTypeVal: String?
        var osVersionVal: String?
        var osBuildVal: String?

        for item in rawValues {
            guard let key = item.descriptorIdentifier?.key else { continue }
            switch key {
            case "name": nameVal = item.stringValue
            case "udid": udidVal = item.stringValue
            case "serialNumber": if udidVal == nil { udidVal = item.stringValue }
            case "reality": realityVal = item.stringValue
            case "state": stateVal = item.stringValue
            case "transportType": transportVal = item.stringValue
            case "bootState": bootStateVal = item.stringValue
            case "platform", "osPlatform": platformVal = item.stringValue
            case "deviceType": deviceTypeVal = item.stringValue
            case "osVersionNumber": osVersionVal = item.osVersionValue?.stringValue ?? item.stringValue
            case "osBuildVersions": osBuildVal = item.osBuildValue?.buildVersion?.name
            default: break
            }
        }

        name = nameVal
        udid = udidVal
        reality = realityVal
        state = stateVal
        transportType = transportVal
        bootState = bootStateVal
        platform = platformVal
        deviceType = deviceTypeVal
        osVersion = osVersionVal
        osBuild = osBuildVal
    }

    /// 実機または起動中のシミュレータのエントリへ変換する。条件を満たさなければ nil。
    public func entry(capabilities: Set<String> = []) -> DeviceEntry? {
        guard let id = identifier, let reality = reality.flatMap(DeviceReality.init(rawValue:)) else { return nil }
        let connectionState = ConnectionState(state ?? "unknown")
        if reality == .simulated && (connectionState != .connected || bootState != "booted") {
            return nil
        }
        return DeviceEntry(
            id: id,
            name: name ?? "(unnamed)",
            udid: udid ?? id,
            connectionState: connectionState,
            reality: reality,
            transport: transportType,
            capabilities: capabilities,
            osName: osDisplayName(platform: platform, deviceType: deviceType),
            osVersion: osVersion,
            osBuild: osBuild
        )
    }

    public var entry: DeviceEntry? {
        entry()
    }
}

// MARK: - CoreDevice DisplayInfo

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
            scale: pointScale
        )
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
public func osDisplayName(platform: String?, deviceType: String?) -> String? {
    guard let platform else { return nil }
    return platform == "iOS" && deviceType == "iPad" ? "iPadOS" : platform
}
