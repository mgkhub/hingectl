import HingeCtlAppKit
import HingeCtlDevice
import SwiftUI

@main
struct HingeCtlApp: App {
    @State private var store: DeviceStore
    /// 撮影モード(`--screenshot-mode`)の出力先。通常の起動は nil
    private let screenshotOutput = ScreenshotRunner.outputDirectory

    init() {
        let log = AppLog()
        // 撮影モードは、モックのデータで動く(実機・devicectl には触れない)
        if screenshotOutput != nil {
            _store = State(initialValue: DeviceStore(backend: MockBackend(), log: log))
            return
        }
        // CoreDevice 層の知らせ・警告を、ログ欄へ流す(呼び出しは任意のスレッドから来る)
        HingeLog.sink = { level, message in
            Task { @MainActor in log.append(level == .warning ? .warning : .note, message) }
        }
        _store = State(initialValue: DeviceStore(backend: LiveBackend(), log: log))
    }

    var body: some Scene {
        WindowGroup(Strings.appName) {
            RootView(store: store)
                .frame(minWidth: 860, minHeight: 600)
                .task {
                    if let output = screenshotOutput {
                        await ScreenshotRunner.run(store: store, output: output)
                    } else {
                        store.startPolling()
                    }
                }
                // 撮った画像の一時ファイルを残さない
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.detail?.discardScreenshot()
                }
        }
    }
}
