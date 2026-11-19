import Foundation

// 内蔵ディスプレイの状態(`devicectl device info displays`)の解析と、`posture` の表示の組み立て(JSON は JSONOutput.swift)。

/// バックライトの状態(`devicectl` の `backlightState`)。`off` と `unknown` 以外(`activeOn` / `dim` など)は点灯とみなす。
public enum Backlight: Equatable, ExpressibleByStringLiteral {
    case off
    /// デバイスが報告しない(古い OS など)
    case unknown
    case lit(String)

    public init(_ text: String) {
        switch text {
        case "off": self = .off
        case "unknown": self = .unknown
        default: self = .lit(text)
        }
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var text: String {
        switch self {
        case .off: return "off"
        case .unknown: return "unknown"
        case .lit(let text): return text
        }
    }

    /// 点灯しているか(消灯でも、報告が無いのでもない)
    public var isLit: Bool {
        switch self {
        case .off, .unknown: return false
        case .lit: return true
        }
    }
}

public struct DisplayState: Equatable {
    public let name: String
    public let uniqueId: String
    public let displayId: Int?
    public let primary: Bool
    public var active: Bool
    public let backlight: Backlight
    public let rotation: String
    public let width: Int?
    public let height: Int?
    public let scale: Int?

    public var isLit: Bool { backlight.isLit }

    public init(name: String, uniqueId: String, displayId: Int? = nil, primary: Bool, active: Bool, backlight: Backlight,
                rotation: String = "portrait", width: Int? = nil, height: Int? = nil, scale: Int? = nil) {
        self.name = name
        self.uniqueId = uniqueId
        self.displayId = displayId
        self.primary = primary
        self.active = active
        self.backlight = backlight
        self.rotation = rotation
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// CoreDevice の `RemoteDevice.displayInfo` の JSON から、内蔵(integrated)ディスプレイを読み、
/// UI を載せているディスプレイの添字を返す。
public func decodeDisplays(data: Data) throws -> (displays: [DisplayState], active: Int?) {
    guard let list = try? JSONDecoder().decode(DisplayList.self, from: data) else {
        throw CLIError("The device display information cannot be read")
    }
    var displays = list.displays.compactMap(\.state)
    guard !displays.isEmpty else { throw CLIError("The device reports no integrated display") }
    var activeIndex = displays.firstIndex { $0.active }
    if activeIndex == nil && displays.count == 1 {
        displays[0].active = true
        activeIndex = 0
    }
    return (displays, activeIndex)
}

/// 読めなかった項目(角度・向き)は `unavailable` と表示する。
public func postureLines(
    udid: String, name: String, mechanicalAngle: Double?, sensorAngle: Double? = nil, orientation: OrientationField, displays: [DisplayState]
) -> [String] {
    let angleString: String
    if let mechanicalAngle {
        if let sensorAngle, abs(sensorAngle - mechanicalAngle) > 0.1 {
            angleString = "\(angleText(mechanicalAngle)) (sensor: \(angleText(sensorAngle)))"
        } else {
            angleString = angleText(mechanicalAngle)
        }
    } else {
        angleString = "unavailable"
    }

    var lines = [
        "device: \(name) (\(udid))",
        "angle: \(angleString)",
        "orientation: \(orientation.text)",
    ]
    for display in displays {
        var flags = ""
        if display.primary { flags += " (primary)" }
        if display.active { flags += " (active)" }
        lines.append("display: \(display.name)\(flags) (backlight: \(display.backlight.text))")
    }
    return lines
}
