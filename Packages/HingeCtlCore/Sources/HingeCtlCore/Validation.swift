import Foundation

/// 実行時のエラー(実機が無い、送信失敗など)。ArgumentParser が `Error: <message>` と出し、終了コードは 1。
/// 引数の誤り(`ValidationError`、終了コード 64)とは区別する。
public struct CLIError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

public func angleText(_ degrees: Double) -> String { String(format: "%.1f", degrees) }
