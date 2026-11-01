import Foundation

/// `sweep` の送信計画。`from` から `to` まで `seconds` 秒かけて、60Hz の等間隔で角度を送る。
public struct SweepPlan: Equatable {
    public let from: Double
    public let to: Double
    public let seconds: Double

    public init(from: Double, to: Double, seconds: Double) {
        self.from = from
        self.to = to
        self.seconds = seconds
    }

    /// `seconds` が 0 でも最小 1(`from` を送り、すぐ `to` を送る)
    public var steps: Int { max(1, Int((seconds * 60).rounded())) }

    /// `index` は 0〜`steps`
    public func angle(at index: Int) -> Double {
        from + (to - from) * Double(index) / Double(steps)
    }

    /// 開始からの絶対時刻(秒)。間隔ではなく絶対時刻にすることで、送信や起床の遅れが累積しない。
    public func time(at index: Int) -> Double {
        seconds * Double(index) / Double(steps)
    }
}
