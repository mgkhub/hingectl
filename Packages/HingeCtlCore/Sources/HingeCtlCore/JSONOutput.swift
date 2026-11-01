import Foundation

// `--json` の出力。Encodable の構造体にして、キー名と型をコンパイルで保証する。
// 出力は 1 行・キー辞書順。値が無い項目は、省略せず `null` で出す(合成された `encode` は nil のキーを省略するため、
// Optional を持つ型は `encode(to:)` を手書きして `encodeNil` を使う)。

/// 変換できなければ nil。数値は最短の表記(119.96)、スラッシュは `\/` にエスケープされる。
public func encodeJSON<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// `get --json`
public struct AngleOutput: Encodable, Equatable {
    public let mechanicalAngle: Double
    public let sensorAngle: Double

    public init(mechanicalAngle: Double, sensorAngle: Double) {
        self.mechanicalAngle = mechanicalAngle
        self.sensorAngle = sensorAngle
    }
}

/// `orientation --json`
public struct OrientationOutput: Encodable, Equatable {
    public let orientation: String
    public init(orientation: OrientationName?) { self.orientation = orientationText(orientation) }
}

/// `screenshot --json`
public struct ScreenshotOutput: Encodable, Equatable, Sendable {
    public let display: String
    public let path: String
    public init(display: String, path: String) {
        self.display = display
        self.path = path
    }
}

/// `posture --json` の 1 つのディスプレイ
public struct DisplayOutput: Encodable, Equatable {
    public let name: String
    public let id: Int?
    public let primary: Bool
    public let active: Bool
    public let backlight: String
    public let rotation: String
    /// `[幅, 高さ]`。値が無い要素は `null`
    public let size: [Int?]
    public let scale: Int?

    public init(_ display: DisplayState) {
        name = display.name
        id = display.displayId
        primary = display.primary
        active = display.active
        backlight = display.backlight.text
        rotation = display.rotation
        size = [display.width, display.height]
        scale = display.scale
    }

    private enum CodingKeys: String, CodingKey { case name, id, primary, active, backlight, rotation, size, scale }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
        try container.encode(primary, forKey: .primary)
        try container.encode(active, forKey: .active)
        try container.encode(backlight, forKey: .backlight)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(size, forKey: .size)
        if let scale { try container.encode(scale, forKey: .scale) } else { try container.encodeNil(forKey: .scale) }
    }
}

/// `posture --json`
public struct PostureOutput: Encodable, Equatable {
    public struct Device: Encodable, Equatable {
        public let udid: String
        public let name: String
    }

    public let device: Device
    /// 物理ヒンジ角(mechanicalAngle)。読めなかったときは `null`
    public let mechanicalAngle: Double?
    /// 内蔵センサーが検出・推定した角度(sensorAngle)。取得できない場合は `null`
    public let sensorAngle: Double?
    /// 向きが読めなかったときは `null`
    public let orientation: OrientationField
    /// UI を載せているディスプレイの名前。無ければ `null`
    public let activeDisplay: String?
    public let displays: [DisplayOutput]

    public init(udid: String, name: String, mechanicalAngle: Double?, sensorAngle: Double? = nil, orientation: OrientationField, displays: [DisplayState], active: Int?) {
        device = Device(udid: udid, name: name)
        self.mechanicalAngle = mechanicalAngle
        self.sensorAngle = sensorAngle
        self.orientation = orientation
        activeDisplay = active.map { displays[$0].name }
        self.displays = displays.map(DisplayOutput.init)
    }

    private enum CodingKeys: String, CodingKey { case device, mechanicalAngle, sensorAngle, orientation, activeDisplay, displays }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(device, forKey: .device)
        if let mechanicalAngle { try container.encode(mechanicalAngle, forKey: .mechanicalAngle) } else { try container.encodeNil(forKey: .mechanicalAngle) }
        if let sensorAngle { try container.encode(sensorAngle, forKey: .sensorAngle) } else { try container.encodeNil(forKey: .sensorAngle) }
        if orientation == .unavailable {
            try container.encodeNil(forKey: .orientation)
        } else {
            try container.encode(orientation.text, forKey: .orientation)
        }
        if let activeDisplay {
            try container.encode(activeDisplay, forKey: .activeDisplay)
        } else {
            try container.encodeNil(forKey: .activeDisplay)
        }
        try container.encode(displays, forKey: .displays)
    }
}
