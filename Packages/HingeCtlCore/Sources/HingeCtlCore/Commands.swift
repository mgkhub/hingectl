import ArgumentParser
import Foundation

// hingectl のコマンド定義。各サブコマンドは解釈結果を `Request` として返すだけで、実行(CoreDevice を呼ぶ処理)は executable が行う。
// CoreDevice に依存しないこのモジュールに置くことで、arm64 の `swift test` で `parseAsRoot` を検証できる。
//
// ユーザー向けの文言は英語に統一している(ArgumentParser の固定文言も英語のため)。

extension OrientationName: ExpressibleByArgument {}

extension RotationDirection: ExpressibleByArgument {}

// MARK: - 解釈の結果

public enum Command: Equatable {
    case list
    case setAngle(Double)
    case sweep(SweepPlan)
    case get(sensor: Bool)
    case posture
    case screenshot(path: String)
    case rotate(RotationDirection)
    case orient(OrientationName)
    case orientation
    case watch(sensor: Bool, count: Int?)

    public static var get: Command { .get(sensor: false) }
    public static func watch(count: Int? = nil) -> Command { .watch(sensor: false, count: count) }

    /// ヒンジの読み書きを要するか。true のコマンドは、ヒンジ非対応のデバイスでは、何も送らずにエラーにする。
    public var requiresHinge: Bool {
        switch self {
        case .setAngle, .sweep, .get, .watch: return true
        case .list, .posture, .screenshot, .rotate, .orient, .orientation: return false
        }
    }
}

/// 解釈済みのリクエスト
public struct Request: Equatable {
    public var command: Command
    /// `-d` の値。未指定なら環境変数 `HINGECTL_DEVICE`(空は無視)。どちらも無ければ nil
    public var device: String?
    /// 角度・向きが反映されるのを待つ秒数。0 なら確認しない。`-t` を持たないコマンドでは使われない
    public var timeout: Double
    public var json: Bool
}

/// 解釈後に `Request` を作れるサブコマンド。実行は `runHingeCtl` が、`run()` の代わりに executable へ渡して行う。
public protocol HingeSubcommand: ParsableCommand {
    func request(environment: [String: String]) -> Request
}

// MARK: - 共通オプション

/// `-d/--device`。コマンドの後ろに置く。
public struct DeviceOptions: ParsableArguments {
    @Option(name: [.short, .long], help: ArgumentHelp(
        "Target device (a physical device or a running simulator): hardware UDID, CoreDevice identifier, or name. Defaults to $HINGECTL_DEVICE, or the connected device that supports the hinge; if several do, you are asked to choose (when run in a terminal). A device without a hinge can be named here to run the commands that do not need one (posture, orientation, rotate, orient, screenshot).",
        valueName: "device"))
    var device: String?

    public init() {}

    func resolved(_ environment: [String: String]) -> String? {
        device ?? environment["HINGECTL_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// `-t` にかけられる秒数の上限(理由は `HingeLimits.timeout`)
let maxTimeoutSeconds = HingeLimits.timeout.upperBound

/// `-t/--timeout`。角度・向きを変えるコマンドだけに付ける。
public struct TimeoutOptions: ParsableArguments {
    @Option(name: [.short, .long], help: ArgumentHelp(
        "Seconds to wait for the change to take effect (0 to 3600). 0 sends without confirming.",
        valueName: "seconds"))
    var timeout: Double = 2

    public init() {}

    public mutating func validate() throws {
        guard HingeLimits.timeout.contains(timeout) else {
            throw ValidationError("Timeout must be a number from 0 to \(Int(maxTimeoutSeconds)): \(String(format: "%g", timeout))")
        }
    }
}

/// `-j/--json`。出力のあるコマンドだけに付ける(付けていないコマンドでは、不明なオプションとして拒否される)。
public struct JSONOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Print JSON.")
    var json = false

    public init() {}
}

/// `sweep` の秒数の上限(理由は `HingeLimits.sweepSeconds`)
let maxSweepSeconds = HingeLimits.sweepSeconds.upperBound

/// 0〜180 の角度。範囲外は誤りであり、黙って丸めない。
func validateAngle(_ value: Double, name: String) throws {
    guard HingeLimits.angle.contains(value) else {
        throw ValidationError("\(name) must be a number from 0 to 180: \(String(format: "%g", value))")
    }
}

// MARK: - ルート

public struct HingeCtl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hingectl",
        abstract: "Control the hinge angle and orientation of a foldable iPhone (iPhone Duo).",
        discussion: """
        Reads and writes the hinge angle and orientation of a connected device through CoreDevice.
        Options go after the subcommand, for example: hingectl get --json
        """,
        version: "0.0.1",
        subcommands: [
            SetCommand.self, OpenCommand.self, CloseCommand.self, HalfCommand.self, SweepCommand.self,
            GetCommand.self, PostureCommand.self, ScreenshotCommand.self,
            RotateCommand.self, OrientCommand.self, OrientationCommand.self,
            ListCommand.self, WatchCommand.self,
        ])

    public init() {}
}

// MARK: - 角度を変えるコマンド(-d と -t)

public struct SetCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(commandName: "set", abstract: "Set the hinge angle.")

    @Argument(help: ArgumentHelp("Hinge angle in degrees: 0 (closed) to 180 (flat).", valueName: "degrees"))
    var degrees: Double
    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func validate() throws { try validateAngle(degrees, name: "Angle (degrees)") }

    public func request(environment: [String: String]) -> Request {
        Request(command: .setAngle(degrees), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

public struct OpenCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Unfold flat (180°).", aliases: ["flat", "unfolded"])

    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .setAngle(180), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

public struct CloseCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "close", abstract: "Fold closed (0°).", aliases: ["closed", "folded"])

    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .setAngle(0), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

public struct HalfCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "half", abstract: "Half-open (90°).", aliases: ["half-open"])

    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .setAngle(90), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

public struct SweepCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "sweep", abstract: "Animate the hinge between two angles.")

    @Argument(help: ArgumentHelp("Start angle in degrees (0 to 180).", valueName: "from"))
    var from: Double
    @Argument(help: ArgumentHelp("End angle in degrees (0 to 180).", valueName: "to"))
    var to: Double
    @Argument(help: ArgumentHelp("Duration in seconds (0 to 3600).", valueName: "seconds"))
    var seconds: Double = 1
    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func validate() throws {
        try validateAngle(from, name: "Start angle (from)")
        try validateAngle(to, name: "End angle (to)")
        guard HingeLimits.sweepSeconds.contains(seconds) else {
            throw ValidationError("Duration (seconds) must be a number from 0 to \(Int(maxSweepSeconds)): \(String(format: "%g", seconds))")
        }
    }

    public func request(environment: [String: String]) -> Request {
        Request(command: .sweep(SweepPlan(from: from, to: to, seconds: seconds)),
                device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

// MARK: - 向きを変えるコマンド(-d と -t)

public struct RotateCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "rotate", abstract: "Rotate 90°, like Device Hub's Rotate Left/Right.")

    @Argument(help: ArgumentHelp("Direction: left or right (l and r also work).", valueName: "direction"))
    var direction: RotationDirection
    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .rotate(direction), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

public struct OrientCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(commandName: "orient", abstract: "Set the orientation.")

    @Argument(help: ArgumentHelp("Orientation to set.", valueName: "orientation"))
    var orientation: OrientationName
    @OptionGroup var target: DeviceOptions
    @OptionGroup var wait: TimeoutOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .orient(orientation), device: target.resolved(environment), timeout: wait.timeout, json: false)
    }
}

// MARK: - 読み取りのコマンド(-d と -j。list は -j のみ)

public struct GetCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(commandName: "get", abstract: "Print the current hinge angle.")

    @Flag(name: .long, help: "Print the sensor-measured angle instead of mechanical angle.")
    var sensor = false
    @OptionGroup var target: DeviceOptions
    @OptionGroup var output: JSONOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .get(sensor: sensor), device: target.resolved(environment), timeout: 2, json: output.json)
    }
}

public struct PostureCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "posture", abstract: "Print the angle, orientation, and integrated displays.")

    @OptionGroup var target: DeviceOptions
    @OptionGroup var output: JSONOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .posture, device: target.resolved(environment), timeout: 2, json: output.json)
    }
}

public struct OrientationCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "orientation", abstract: "Print the current orientation.")

    @OptionGroup var target: DeviceOptions
    @OptionGroup var output: JSONOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .orientation, device: target.resolved(environment), timeout: 2, json: output.json)
    }
}

public struct ScreenshotCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshot", abstract: "Save a PNG of the display that hosts the UI.")

    @Argument(help: ArgumentHelp("Output path (must end with .png).", valueName: "path"))
    var path: String
    @OptionGroup var target: DeviceOptions
    @OptionGroup var output: JSONOptions

    public init() {}

    public func validate() throws {
        guard path.lowercased().hasSuffix(".png") else {
            throw ValidationError("Output path must end with .png: \(path)")
        }
    }

    public func request(environment: [String: String]) -> Request {
        Request(command: .screenshot(path: path), device: target.resolved(environment), timeout: 2, json: output.json)
    }
}

public struct WatchCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "watch", abstract: "Print hinge angle changes until interrupted.")

    @Flag(name: .long, help: "Print the sensor-measured angle instead of mechanical angle.")
    var sensor = false
    @Option(help: ArgumentHelp("Stop after printing this many readings.", valueName: "count"))
    var count: Int?
    @OptionGroup var target: DeviceOptions
    @OptionGroup var output: JSONOptions

    public init() {}

    public func validate() throws {
        if let count, count <= 0 { throw ValidationError("--count must be a positive integer: \(count)") }
    }

    public func request(environment: [String: String]) -> Request {
        Request(command: .watch(sensor: sensor, count: count), device: target.resolved(environment), timeout: 2, json: output.json)
    }
}

public struct ListCommand: HingeSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List physical devices and running simulators.")

    @OptionGroup var output: JSONOptions

    public init() {}

    public func request(environment: [String: String]) -> Request {
        Request(command: .list, device: nil, timeout: 2, json: output.json)
    }
}
