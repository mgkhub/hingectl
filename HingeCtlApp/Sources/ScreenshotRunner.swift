import AppKit
import HingeCtlAppKit

/// README 用のスクリーンショットを、モックのデータで自動で撮る(`make screenshots`)。
/// 起動引数 `--screenshot-mode <出力先のフォルダ>` のときだけ動き、ライトとダークの 2 枚を書いて、終了する。
/// 取るのは自分のウィンドウだけなので、画面収録の許可は要らない(ScreenCaptureKit と違い、`CGWindowListCreateImage` は許可を求めない)。
enum ScreenshotRunner {
    static let argument = "--screenshot-mode"

    /// 撮影モードの出力先。通常の起動(引数なし)は nil
    static var outputDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(store: DeviceStore, output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            await store.refresh()
            store.log.append(.note, "Connected to iPhone Duo")
            store.selectedID = store.entries.first?.id
            guard let detail = store.detail else { throw Failure("no device was selected") }
            guard await waitUntil({ detail.phase == .ready && detail.posture != nil }) else {
                throw Failure("the device did not become ready")
            }

            guard let window = await waitForWindow() else { throw Failure("no window") }
            // 前面に出す(裏にあると、タイトルバーが非アクティブの見た目になる)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try resize(window)
            let backdrop = makeBackdrop(behind: window)

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                // サイドバーは半透明で、背後を透かす。背後に何があっても同じ画像になるよう、単色にする(ライトは白、ダークは黒)
                backdrop.backgroundColor = appearance == .aqua ? .white : .black
                // 外観の切り替えが、画面に行き渡るのを待つ
                try await Task.sleep(for: .milliseconds(800))
                let file = output.appendingPathComponent("gui-\(name).png")
                try capture(window).write(to: file)
                print("Wrote \(file.path)")
            }
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Screenshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor
    private static func waitForWindow() async -> NSWindow? {
        _ = await waitUntil({ NSApp.windows.contains { $0.isVisible && $0.contentView != nil } })
        return NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    /// 撮影用のウィンドウの大きさ(全項目が入る高さ)。固定で、実行する Mac によって変えない
    private static let windowSize = NSSize(width: 1040, height: 800)

    /// 撮影するウィンドウの背後に敷く、単色の窓。サイドバーが透かす背後を固定し、デスクトップや他のウィンドウが画像に映り込むのも防ぐ。
    @MainActor
    private static func makeBackdrop(behind window: NSWindow) -> NSWindow {
        let backdrop = NSWindow(contentRect: (window.screen ?? NSScreen.main)?.frame ?? window.frame,
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.isReleasedWhenClosed = false
        backdrop.orderFront(nil)
        window.order(.above, relativeTo: backdrop.windowNumber)
        return backdrop
    }

    /// ウィンドウを撮影用の大きさにする。画面が足りないと、下の項目が切れた画像になるため、書かずに失敗する。
    @MainActor
    private static func resize(_ window: NSWindow) throws {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { throw Failure("no screen") }
        guard visible.height >= windowSize.height, visible.width >= windowSize.width else {
            throw Failure("the screen is too small: the screenshot window needs \(Int(windowSize.width))x\(Int(windowSize.height)) pt, "
                          + "but the visible area is \(Int(visible.width))x\(Int(visible.height)) pt. Use a larger display")
        }
        window.setFrame(NSRect(x: visible.minX, y: visible.maxY - windowSize.height, width: windowSize.width, height: windowSize.height),
                        display: true)
        // 画面の端などで、思った大きさにならなかったときも、切れた画像を書かない
        guard window.frame.size == windowSize else {
            throw Failure("the window could not be resized to \(Int(windowSize.width))x\(Int(windowSize.height)) pt (got \(window.frame.size))")
        }
    }

    /// ウィンドウ全体(タイトルバーを含む。影は含まない)を PNG にする。
    /// `NSView.cacheDisplay` や `CALayer.render` では、SwiftUI のリストやスクロール領域が描かれない(空白になる)。
    /// ScreenCaptureKit は、自分のウィンドウでも画面収録の許可を求める。そこで、ウィンドウサーバーが合成した画像を返す
    /// `CGWindowListCreateImage` を使う(自分のウィンドウは、許可なしで取れる)。この関数は、SDK では使用不可と宣言されているが、
    /// システムには残っているため、実行時に探して呼ぶ(この GUI は、もともと非公開 API を使う)。
    @MainActor
    private static func capture(_ window: NSWindow) throws -> Data {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            throw Failure("CGWindowListCreateImage is not available in this macOS")
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3  // kCGWindowListOptionIncludingWindow
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        guard let image = createImage(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue() else {
            throw Failure("cannot capture the window")
        }
        let rawRep = NSBitmapImageRep(cgImage: image)
        let rep = rawRep.retagging(with: .sRGB) ?? rawRep
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure("cannot encode the image")
        }
        return data
    }
}
