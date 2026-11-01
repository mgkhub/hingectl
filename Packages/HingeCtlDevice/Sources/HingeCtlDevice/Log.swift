import Foundation

/// 状況の通知と警告の出力先。既定は標準エラー(CLI はそのまま使う)。GUI は `sink` を差し替えて、自分のログ欄へ流す。
public enum HingeLog {
    public enum Level: Sendable {
        /// 警告ではない状況の知らせ(数秒かかる処理の前に出す)
        case note
        case warning
    }

    public nonisolated(unsafe) static var sink: @Sendable (Level, String) -> Void = { level, message in
        let prefix = level == .warning ? "hingectl: warning: " : "hingectl: "
        FileHandle.standardError.write(Data((prefix + message + "\n").utf8))
    }

    static func note(_ message: String) { sink(.note, message) }
    static func warn(_ message: String) { sink(.warning, message) }
}
