import Foundation

/// スクリーンショットを保存するときの、ファイル名の既定値。macOS のスクリーンショットと同じ形式で、
/// `Screenshot <デバイス名> 2026-10-31 at 15.30.56.png`。日時は、保存の操作をした時刻ではなく、撮影した時刻。
public func screenshotFileName(deviceName: String, capturedAt: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    // ファイル名に使えない `/` と `:` は、デバイス名から除く
    let safeName = deviceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return "Screenshot \(safeName) \(formatter.string(from: capturedAt)).png"
}
