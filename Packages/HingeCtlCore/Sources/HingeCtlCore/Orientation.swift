import Foundation

/// 向き(`orient` の引数)。値は Device Hub のイベントと同じ kebab-case。
public enum OrientationName: String, CaseIterable, Equatable {
    case portrait
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"
    case portraitUpsideDown = "portrait-upside-down"
}

extension OrientationName {
    /// 順序は Device Hub と同じ:
    /// Rotate Left は portrait → landscape-left → portrait-upside-down → landscape-right、Rotate Right は逆回り。
    public func rotated(_ direction: RotationDirection) -> OrientationName {
        switch (direction, self) {
        case (.left, .portrait): return .landscapeLeft
        case (.left, .landscapeLeft): return .portraitUpsideDown
        case (.left, .portraitUpsideDown): return .landscapeRight
        case (.left, .landscapeRight): return .portrait
        case (.right, .portrait): return .landscapeRight
        case (.right, .landscapeRight): return .portraitUpsideDown
        case (.right, .portraitUpsideDown): return .landscapeLeft
        case (.right, .landscapeLeft): return .portrait
        }
    }

    /// ディスプレイの描画回転(rot0/rot90/rot180/rot270)から端末の論理向きを逆算する。
    /// 内側画面(iPhone Duo の LCD-1)はパネルが 90° 回転して内蔵されているため、基準角が rot90 となる。
    public init?(rotation: DisplayRotation, isInnerDisplay: Bool) {
        if isInnerDisplay {
            // Duo 内側画面(LCD-1): rot90 が portrait 基準
            switch rotation {
            case .rot90:  self = .portrait
            case .rot0:   self = .landscapeLeft
            case .rot180: self = .landscapeRight
            case .rot270: self = .portraitUpsideDown
            case .unknown: return nil
            }
        } else {
            // 標準画面(通常 iPhone, iPad, Duo 外側 LCD): rot0 が portrait 基準
            switch rotation {
            case .rot0:   self = .portrait
            case .rot270: self = .landscapeLeft
            case .rot90:  self = .landscapeRight
            case .rot180: self = .portraitUpsideDown
            case .unknown: return nil
            }
        }
    }
}

/// 向きの表示。デバイスが使える向きを報告しない(`nil`)ときは `unknown`。
public func orientationText(_ orientation: OrientationName?) -> String { orientation?.rawValue ?? "unknown" }

/// `posture` の向きの欄。「デバイスが向きを報告しない」と「読み取りに失敗した」を区別する。
public enum OrientationField: Equatable {
    case known(OrientationName)
    /// 読めたが、使える向きではない(平置きだけ、など)
    case unknown
    /// 読み取りに失敗した(ヒンジ非対応のデバイスで、向きの制御が無い場合など)。JSON は `null`
    case unavailable

    public var text: String {
        switch self {
        case .known(let name): return name.rawValue
        case .unknown: return "unknown"
        case .unavailable: return "unavailable"
        }
    }
}

public enum RotationDirection: String, CaseIterable, Equatable {
    case left
    case right

    /// `left` / `l` / `right` / `r`
    public init?(argument: String) {
        switch argument {
        case "left", "l": self = .left
        case "right", "r": self = .right
        default: return nil
        }
    }
}
