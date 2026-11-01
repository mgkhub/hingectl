/// `posture` の読み取り結果。ヒンジ非対応のデバイスで読めなかった項目は、`mechanicalAngle` が nil、`orientation` が `.unavailable`、
/// ディスプレイが空になる。
public struct PostureSnapshot: Equatable {
    public let mechanicalAngle: Double?
    public let sensorAngle: Double?
    public let orientation: OrientationField
    public let displays: [DisplayState]
    public let active: Int?

    public init(mechanicalAngle: Double?, sensorAngle: Double? = nil, orientation: OrientationField, displays: [DisplayState], active: Int?) {
        self.mechanicalAngle = mechanicalAngle
        self.sensorAngle = sensorAngle
        self.orientation = orientation
        self.displays = displays
        self.active = active
    }
}
