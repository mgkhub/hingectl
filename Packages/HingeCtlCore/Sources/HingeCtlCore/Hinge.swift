import Foundation

// ヒンジの読み取りに関する、CoreDevice 非依存の型と関数(executable が CoreDevice の値をこれらに変換して使う)。

/// デバイスがヒンジ角を扱えるか。問い合わせの失敗(`unknown`)を、非対応(`unsupported`)と区別する。
/// 一時的な失敗を「非対応」と取り違えると、対応デバイスが候補から消えたり、読めない項目を黙って省いたりする。
public enum HingeSupport: Equatable {
    case supported
    /// ヒンジを持たない(CoreDevice が、この capability は未対応と答えた、または対応していないと報告した)
    case unsupported
    case unknown(String)
}

/// ヒンジ角の 1 回の読み取り(単位は度)。`--json` の `watch` の出力にもなる。
public struct HingeReading: Equatable, Sendable, Encodable {
    /// ヒンジ蝶番の機械角(設定角に追従する物理角度)
    public let mechanicalAngle: Double
    /// 内蔵センサー(CoreMotion等)が検出・推定した角度
    public let sensorAngle: Double
    public let isValid: Bool
    public let minAngle: Double
    public let maxAngle: Double
    public let timestamp: Double

    public init(mechanicalAngle: Double, sensorAngle: Double, isValid: Bool, minAngle: Double, maxAngle: Double, timestamp: Double) {
        self.mechanicalAngle = mechanicalAngle
        self.sensorAngle = sensorAngle
        self.isValid = isValid
        self.minAngle = minAngle
        self.maxAngle = maxAngle
        self.timestamp = timestamp
    }

    /// JSON のキー(`isValid` は `valid`、`minAngle` / `maxAngle` は `min` / `max`)
    private enum CodingKeys: String, CodingKey {
        case mechanicalAngle, sensorAngle, timestamp
        case isValid = "valid"
        case minAngle = "min"
        case maxAngle = "max"
    }
}

public enum FirstElement<Element> {
    case found(Element)
    /// 締切までに、条件を満たす要素が来なかった
    case timedOut
    /// 条件を満たす要素が来ないまま、列が終わった
    case ended
}

/// 非同期の列から、条件を満たす最初の要素を、`timeout` までの間だけ待つ。
/// 列のエラーは、そのまま投げる(握りつぶすと、切断などの本当の原因が「時間切れ」に見えてしまう)。
public func firstElement<S: AsyncSequence>(
    of sequence: S, timeout: Duration, where predicate: @escaping (S.Element) -> Bool
) async throws -> FirstElement<S.Element> {
    try await withThrowingTaskGroup(of: FirstElement<S.Element>.self) { group in
        group.addTask {
            for try await element in sequence where predicate(element) { return .found(element) }
            return .ended
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return .timedOut
        }
        defer { group.cancelAll() }
        return try await group.next() ?? .ended
    }
}

/// CoreDevice のエラー(ドメインとコード)から、ヒンジへの対応を判定する。**この分類が、「非対応」の誤断定を防ぐ要**。
/// ドメイン `com.apple.dt.CoreDeviceError` かつコード 1001(「この capability は、このデバイスでは未対応」)のときだけ
/// `unsupported`。それ以外の失敗は、一時的なものかもしれないので、理由を持つ `unknown` にする。
/// (1001 は、デバイスが切断中のときにも返るため、意味を持つのは接続中のデバイスに対してだけ。)
public func classifyHingeError(domain: String, code: Int, reason: String) -> HingeSupport {
    if domain == "com.apple.dt.CoreDeviceError" && code == 1001 { return .unsupported }
    return .unknown(reason)
}

/// `posture` の角度。ヒンジ非対応のデバイスだけが、読まずに nil(`unavailable`)になる。
/// 対応・不明のデバイスでは、読み取りの失敗をそのまま投げる(向き・ディスプレイと同じ扱い。
/// 握りつぶすと、非対応の `null` と読み取りの失敗が区別できなくなる)。
public func postureAngle<T>(support: HingeSupport, read: () async throws -> T) async throws -> T? {
    if support == .unsupported { return nil }
    return try await read()
}
