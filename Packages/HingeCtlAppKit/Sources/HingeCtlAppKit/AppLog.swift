import Foundation
import Observation

public struct LogLine: Identifiable, Equatable {
    public enum Level: Equatable { case note, warning, error }

    public let id: Int
    public let date: Date
    public let level: Level
    public let text: String
}

/// 画面のログ欄の内容。状況の知らせ・警告・操作の失敗を、新しいものを後ろに足して保持する。
@MainActor @Observable
public final class AppLog {
    public private(set) var lines: [LogLine] = []
    private var nextID = 0
    private let limit: Int

    public init(limit: Int = 500) { self.limit = limit }

    public func append(_ level: LogLine.Level, _ text: String, date: Date = Date()) {
        lines.append(LogLine(id: nextID, date: date, level: level, text: text))
        nextID += 1
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    public func clear() { lines.removeAll() }
}
