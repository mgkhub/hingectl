import Foundation

// デバイス(実機・起動中のシミュレータ)の選択と判定ロジック。

/// 実機か、Mac 上のシミュレータか
public enum DeviceReality: String, Encodable {
    case physical
    case simulated
}

/// 接続状態。未知の値は、そのまま `other` に持つ。
public enum ConnectionState: Equatable, ExpressibleByStringLiteral, Encodable {
    case connected
    case disconnected
    case unavailable
    case other(String)

    public init(_ text: String) {
        switch text {
        case "connected": self = .connected
        case "disconnected": self = .disconnected
        case "unavailable": self = .unavailable
        default: self = .other(text)
        }
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var text: String {
        switch self {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .unavailable: return "unavailable"
        case .other(let text): return text
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct DeviceEntry: Equatable, Encodable {
    /// CoreDevice の識別子(UUID)。シミュレータでは UDID と同じ
    public let id: String
    public let name: String
    /// ハードウェア UDID
    public let udid: String
    public let connectionState: ConnectionState
    public var reality: DeviceReality = .physical
    /// 経路(`wired` / `localNetwork` など)。経路が無い(つながらない)ときは nil。
    public var transport: String? = nil
    /// デバイスが備える機能識別子。切断中は一部のみ判定可能。
    public var capabilities: Set<String> = []
    public var isConnected: Bool { connectionState == .connected }
    public var isSimulator: Bool { reality == .simulated }
    /// 切断中(トンネルがアイドル)だが、経路があり、接続を張ればつながる見込みがあるか。
    /// 経路が無い(`unavailable`)ものと、`sameMachine`(停止中のシミュレータ)は含まない。
    public var isWakeable: Bool {
        guard connectionState == .disconnected, let transport else { return false }
        return transport != "sameMachine"
    }
    /// 向きの遠隔操作の機能(切断中の一覧にも載る)
    public static let orientationControlFeature = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    /// ヒンジに対応している**見込み**があるか(起こす順序を決める手がかり)。
    /// 切断中の状態ではヒンジ用の機能(`monitormotion` など)は載らない。実測では、Duo だけが向きの遠隔操作を載せ、
    /// 経路のある iPad mini・iPad 10th・iPhone 15 Pro・iPhone SE には無かった(SE は接続中に載る)。
    /// ただし「ヒンジ対応なら必ず載る」とは言えないため判定には使わず、起こす順序にだけ使う(確定判定は接続後の `hingeSupport`)。
    public var mayHaveHinge: Bool { capabilities.contains(Self.orientationControlFeature) }

    /// OS の名前(`iOS` / `iPadOS` など)・バージョン(例: `27.1`)・ビルド(例: `24A94425`)。一覧に無ければ nil。
    /// 一覧の JSON(`list --json`)と、CLI の出力には含めない(GUI の表示用)。
    public var osName: String? = nil
    public var osVersion: String? = nil
    public var osBuild: String? = nil
    /// 表示用(例: `iOS 27.1`)。バージョンが無ければ nil
    public var osText: String? { osVersion.map { "\(osName ?? "OS") \($0)" } }

    public init(id: String, name: String, udid: String, connectionState: ConnectionState,
                reality: DeviceReality = .physical, transport: String? = nil, capabilities: Set<String> = [],
                osName: String? = nil, osVersion: String? = nil, osBuild: String? = nil) {
        self.id = id
        self.name = name
        self.udid = udid
        self.connectionState = connectionState
        self.reality = reality
        self.transport = transport
        self.capabilities = capabilities
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    /// `list --json` の出力のキー(`connectionState` は `state`)
    private enum CodingKeys: String, CodingKey {
        case id, name, udid, reality
        case connectionState = "state"
    }
}

/// CoreDevice の `RemoteDevice.deviceInfo` の JSON (プロパティリスト形式)から `DeviceEntry` を型安全に復元する。
public func decodeCoreDeviceRecord(data: Data, capabilities: Set<String> = []) -> DeviceEntry? {
    (try? JSONDecoder().decode(CoreDeviceInfoRecord.self, from: data))?.entry(capabilities: capabilities)
}

/// `list` の 1 行。シミュレータには [simulator] を付ける。
public func listLine(_ entry: DeviceEntry) -> String {
    "\(entry.udid)  \(entry.name)  (\(entry.connectionState.text))" + (entry.isSimulator ? "  [simulator]" : "")
}

/// `-d` を省略して、対象が 1 台に決まったとき、標準エラーへ出す 1 行。
/// 入力を送るコマンドなどが、意図しないデバイスへ黙って届くのを防ぐ。
public func implicitSelectionNote(_ entry: DeviceEntry) -> String {
    "using \(entry.name) (\(entry.isSimulator ? "simulator" : "physical device")) \(entry.udid), the only connected device that supports the hinge; pass -d to choose another"
}

private func deviceLabel(_ entry: DeviceEntry) -> String {
    "\(entry.udid)  \(entry.name)" + (entry.isSimulator ? "  [simulator]" : "")
}

private func deviceList(_ entries: [DeviceEntry]) -> String {
    entries.map { "  " + deviceLabel($0) }.joined(separator: "\n")
}

/// 対話式の問い合わせの行。`choose` の実装側が、標準エラーに出す。
public func choicePromptLines(_ candidates: [DeviceEntry]) -> [String] {
    ["Several connected devices support the hinge:"]
        + candidates.enumerated().map { "  \($0.offset + 1)) " + deviceLabel($0.element) }
}

/// 1〜`count` の整数だけを受け、候補の添字(0 始まり)にする。それ以外(空・数字でない・範囲外・符号つき)は nil。
public func parseChoice(_ input: String, count: Int) -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }),
          let number = Int(text), number >= 1, number <= count else { return nil }
    return number - 1
}

/// 対話式の問い合わせ。`q` と入力の終わり(EOF)は、中止として `CLIError` を投げる。
/// 入出力は、テストで差し替えるため引数で受ける(実際には、表示は標準エラー、入力は標準入力)。
public func promptForDevice(
    _ candidates: [DeviceEntry],
    input: () -> String?,
    output: (String) -> Void
) throws -> DeviceEntry {
    choicePromptLines(candidates).forEach { output($0 + "\n") }
    while true {
        output("Select a device [1-\(candidates.count)] (q to cancel): ")
        guard let line = input() else {
            output("\n")
            throw CLIError("No device was selected")
        }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.lowercased() == "q" { throw CLIError("No device was selected") }
        if let index = parseChoice(answer, count: candidates.count) { return candidates[index] }
        output("Enter a number from 1 to \(candidates.count), or q to cancel.\n")
    }
}

/// `-d` の指定からデバイス(実機・起動中のシミュレータ)を 1 台に絞る。
/// - 指定あり: CoreDevice の識別子 / ハードウェア UDID(大文字小文字を区別しない)/ 名前の完全一致。
///   ヒンジへの対応は問わない(非対応のデバイスでも、ヒンジを使わないコマンドは実行できる)。
/// - 指定なし: 接続中のデバイスを `narrowByCapability` でヒンジ対応のものに絞る(接続中が 1 台でも絞る)。
///   **絞り込みの結果が 0 台のときだけ**、切断中で経路のあるデバイス(`isWakeable`)を `wake` で起こし、
///   つながったものを同じように絞り直す(接続中の対応デバイスがあれば、切断中のものには触れない)。
///   1 台ならそれ。2 台以上なら `choose` で選ばせる(`choose` が無ければ、推測せずエラー)。0 台ならエラー。
/// - 選んだデバイスが切断中(`isWakeable`)なら、`wake` で起こす。接続中でなければエラー。
///
/// `wake` は、渡されたデバイスの接続を張り(上限は呼ぶ側が決める)、**つながったものを、最新の状態にして**返す。
/// 切断中のデバイスには、CoreDevice の API が接続を張らず、対応デバイスでも「非対応」と返すため、先に起こす必要がある。
public func selectDevice(
    from entries: [DeviceEntry],
    query: String?,
    narrowByCapability: ([DeviceEntry]) async -> [DeviceEntry],
    choose: (([DeviceEntry]) async throws -> DeviceEntry)? = nil,
    wake: ([DeviceEntry]) async -> [DeviceEntry] = { _ in [] },
    undetermined: () -> [DeviceEntry] = { [] }
) async throws -> DeviceEntry {
    var chosen: DeviceEntry
    if let query {
        let needle = query.lowercased()
        let matches = entries.filter { $0.id.lowercased() == needle || $0.udid.lowercased() == needle || $0.name == query }
        guard !matches.isEmpty else { throw CLIError("No device matches: \(query) (run 'hingectl list' to see devices)") }
        guard matches.count == 1 else {
            throw CLIError("Several devices match \"\(query)\"; specify the UDID:\n\(deviceList(matches))")
        }
        chosen = matches[0]
        if chosen.isWakeable, let woken = await wake([chosen]).first(where: { $0.id == chosen.id }) { chosen = woken }
    } else {
        var candidates = entries.filter(\.isConnected)
        var foldable = candidates.isEmpty ? [] : await narrowByCapability(candidates)
        // ヒンジ対応の見込みがある端末から先に起こし、見つからなければ、残りも起こす(手がかりが外れても、取りこぼさない)
        let wakeable = entries.filter(\.isWakeable)
        for batch in [wakeable.filter(\.mayHaveHinge), wakeable.filter { !$0.mayHaveHinge }] where foldable.isEmpty && !batch.isEmpty {
            let woken = await wake(batch).filter(\.isConnected)
            guard !woken.isEmpty else { continue }
            candidates += woken
            foldable = await narrowByCapability(woken)
        }
        guard !candidates.isEmpty else { throw CLIError("No device is connected (run 'hingectl list' to see devices)") }
        switch foldable.count {
        case 1:
            chosen = foldable[0]
        case 0:
            var message = "No connected device supports the hinge; to use one anyway, specify it with -d <udid|name>:\n\(deviceList(candidates))"
            // 判定できなかっただけの端末は、対応しているかもしれない(一時的な失敗なら、やり直せば分かる)
            var seen = Set<String>()
            let unknown = undetermined().filter { u in candidates.contains { $0.id == u.id } && seen.insert(u.id).inserted }
            if !unknown.isEmpty {
                message += "\nCould not determine whether these support the hinge (they may, if the failure was temporary; try again):\n\(deviceList(unknown))"
            }
            throw CLIError(message)
        default:
            guard let choose else {
                throw CLIError("Cannot narrow down to one device; specify one with -d <udid|name>:\n\(deviceList(foldable))")
            }
            chosen = try await choose(foldable)
        }
    }
    guard chosen.isConnected else {
        if chosen.connectionState == .unavailable {
            throw CLIError("\(chosen.name) is not reachable (state: unavailable)")
        }
        throw CLIError("\(chosen.name) is not connected (state: \(chosen.connectionState.text))")
    }
    return chosen
}
