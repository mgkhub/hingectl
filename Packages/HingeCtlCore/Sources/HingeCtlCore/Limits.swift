/// 値の範囲。CLI の引数の検証と、GUI の入力で共有する。
public enum HingeLimits {
    /// ヒンジ角(度)。0 が閉じた状態、180 が平ら。範囲外は誤りであり、黙って丸めない。
    public static let angle: ClosedRange<Double> = 0...180

    /// 確認の待ち秒数。上限が無いと、極端に大きい値(例: 1e300)が `Duration` の整数変換で範囲外になり、
    /// メッセージなしにクラッシュする(単体の Swift で確認: `Duration.seconds(1e300)` が trap する)。
    public static let timeout: ClosedRange<Double> = 0...3600

    /// `sweep` の秒数。`timeout` と同じ理由で、`SweepPlan.steps` の整数変換が範囲外になるのを防ぐ(実機で確認)。
    public static let sweepSeconds: ClosedRange<Double> = 0...3600
}
