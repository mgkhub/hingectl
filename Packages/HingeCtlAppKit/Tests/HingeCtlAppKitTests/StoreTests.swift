import Foundation
import HingeCtlCore
import Testing
@testable import HingeCtlAppKit

@MainActor
struct StoreTests {
    /// テストごとの、空の一時フォルダ
    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hingectl-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func makeStore(_ backend: FakeBackend) -> (DeviceStore, AppLog) {
        let log = AppLog()
        return (DeviceStore(backend: backend, log: log), log)
    }

    /// 一覧を取り、先頭を選び、接続が終わるまで待つ
    private func select(_ store: DeviceStore, _ name: String) async -> DeviceDetailStore {
        await store.refresh()
        store.selectedID = "id-\(name)"
        let detail = store.detail!
        _ = await eventually { detail.phase != .idle && detail.phase != .connecting }
        return detail
    }

    @Test func 一覧を取り直して_選ぶと接続して購読が始まる() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(detail.phase == .ready)
        #expect(detail.canUseHinge)
        #expect(backend.openedIDs == ["id-Duo"])
        #expect(await eventually { backend.session.calls.contains("readings") })
        backend.session.emit(angle: 90)
        #expect(await eventually { detail.reading?.mechanicalAngle == 90 })
    }

    @Test func 接続すると_posture_から向きが分かる() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(detail.orientation == .portrait)
        #expect(detail.posture?.mechanicalAngle == 180)
    }

    @Test func 切断中のデバイスは_起こしてから開く() async throws {
        let backend = FakeBackend(devices: [entry("Duo", state: .disconnected)])
        backend.wakeResult = [entry("Duo", state: .connected)]
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(backend.wakeCalls == 1)
        #expect(detail.phase == .ready)
        #expect(detail.entry.isConnected)
    }

    @Test func 起こせなかったら_開かずに失敗する() async throws {
        let backend = FakeBackend(devices: [entry("Duo", state: .disconnected)])
        backend.wakeResult = []
        let (store, log) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(detail.phase == .failed("Could not connect to Duo"))
        #expect(backend.openedIDs.isEmpty)
        #expect(log.lines.last?.level == .error)
    }

    @Test func 到達できないデバイスは_起こさずに失敗する() async throws {
        let backend = FakeBackend(devices: [entry("Duo", state: .unavailable, transport: nil)])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(detail.phase == .failed("Duo is not reachable (state: unavailable)"))
        #expect(backend.wakeCalls == 0)
    }

    @Test func ヒンジ非対応のデバイスは_ヒンジの操作を何も送らず_posture_と向きは使える() async throws {
        let backend = FakeBackend(devices: [entry("SE")])
        backend.session.supportResult = .unsupported
        let (store, _) = makeStore(backend)
        let detail = await select(store, "SE")
        #expect(!detail.canUseHinge)
        #expect(detail.hingeUnavailableReason == "SE does not support the hinge.")
        await detail.setAngle(90)
        detail.sweep(from: 0, to: 90, seconds: 1)
        detail.dragAngle(45)
        #expect(!backend.session.calls.contains { $0.hasPrefix("setAngle") || $0.hasPrefix("sweep") || $0 == "readings" })
        #expect(backend.session.sent.isEmpty)
        #expect(detail.posture != nil)
        // 向きは、CLI の `orient` / `rotate` と同じく、ヒンジが無くても使える
        await detail.setOrientation(.landscapeLeft)
        await detail.rotate(.left)
        #expect(backend.session.calls.contains("orient landscape-left"))
        #expect(backend.session.calls.contains("rotate"))
    }

    @Test func 対応が分からないデバイスは_原因を示して操作を止める() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        backend.session.supportResult = .unknown("timed out")
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(!detail.canUseHinge)
        #expect(detail.hingeUnavailableReason == "Cannot determine whether Duo supports the hinge: timed out")
    }

    @Test func 範囲外の角度は_送らずにログへ出す() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, log) = makeStore(backend)
        let detail = await select(store, "Duo")
        await detail.setAngle(181)
        #expect(!backend.session.calls.contains { $0.hasPrefix("setAngle") })
        #expect(log.lines.last?.text == "Angle must be a number from 0 to 180: 181")
        detail.sweep(from: 0, to: 90, seconds: 3601)
        #expect(!backend.session.calls.contains { $0.hasPrefix("sweep") })
        #expect(log.lines.last?.text == "Duration must be a number from 0 to 3600: 3601")
    }

    @Test func 範囲外のタイムアウトは_送らずにログへ出す() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, log) = makeStore(backend)
        let detail = await select(store, "Duo")
        detail.timeout = 4000
        await detail.setAngle(90)
        #expect(!backend.session.calls.contains { $0.hasPrefix("setAngle") })
        #expect(log.lines.last?.text == "Timeout must be a number from 0 to 3600: 4000")
    }

    @Test func 角度の設定は_待ち秒数を渡し_終わったら_posture_を読み直す() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        detail.timeout = 3
        let before = backend.session.calls.filter { $0 == "posture" }.count
        await detail.setAngle(120)
        #expect(backend.session.calls.contains("setAngle 120.0 3.0"))
        #expect(backend.session.calls.filter { $0 == "posture" }.count == before + 1)
        #expect(detail.busyLabel == nil)
    }

    @Test func 設定の失敗は_ログへ出し_操作できる状態に戻る() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        backend.session.setAngleError = CLIError("The hinge angle did not reach 90.0° within 2.0 seconds")
        let (store, log) = makeStore(backend)
        let detail = await select(store, "Duo")
        await detail.setAngle(90)
        #expect(log.lines.last?.text == "Setting angle failed: The hinge angle did not reach 90.0° within 2.0 seconds")
        #expect(detail.busyLabel == nil)
    }

    @Test func ドラッグ中の送信は間引かれ_最後の値が届き_流し切りは_1_回() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        detail.minSendInterval = .milliseconds(60)
        // 値は、送る間隔より速く、時間をまたいで届く(まとめて渡すと、最新値に畳まれるだけで、間引きを確かめられない)
        for value in stride(from: 0.0, through: 60.0, by: 2) {
            detail.dragAngle(value)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(detail.isDragging)
        detail.endDrag(60)
        #expect(await eventually { backend.session.flushCount == 1 && !detail.isDragging })
        let sent = backend.session.sent
        #expect(sent.last == 60)
        #expect(sent.count >= 2)
        #expect(sent.count < 15)
        #expect(sent == sent.sorted())
        #expect(backend.session.calls.filter { $0 == "beginSending" }.count == 1)
    }

    @Test func ドラッグしていないときの_endDrag_は何もしない() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        detail.endDrag(50)
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.session.sent.isEmpty)
        #expect(backend.session.flushCount == 0)
    }

    @Test func 向きの設定と回転は_表示の向きを更新する() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        await detail.setOrientation(.portraitUpsideDown)
        #expect(backend.session.calls.contains("orient portrait-upside-down"))
        await detail.rotate(.left)
        #expect(detail.orientation == .landscapeLeft)
    }

    @Test func スクリーンショットは_ヒンジ非対応でも撮れる() async throws {
        let backend = FakeBackend(devices: [entry("SE")])
        backend.session.supportResult = .unsupported
        let (store, _) = makeStore(backend)
        let detail = await select(store, "SE")
        detail.screenshotDirectory = scratchDirectory()
        await detail.takeScreenshot()
        #expect(detail.screenshot?.display == "LCD")
    }

    @Test func 一覧から消えたデバイスは_選択が外れる() async throws {
        let backend = FakeBackend(devices: [entry("Duo"), entry("SE")])
        let (store, _) = makeStore(backend)
        _ = await select(store, "Duo")
        backend.devices = [entry("SE")]
        await store.refresh()
        #expect(store.selectedID == nil)
        #expect(store.detail == nil)
    }

    @Test func 一覧の更新は_選択中のデバイスの接続状態に届く() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        backend.devices = [entry("Duo", state: .disconnected)]
        await store.refresh()
        #expect(detail.entry.connectionState == .disconnected)
    }

    @Test func 一覧の取得に失敗しても_同じ失敗はログに積まれない() async throws {
        let backend = FakeBackend(devices: [])
        backend.listError = CLIError("devicectl failed")
        let (store, log) = makeStore(backend)
        await store.refresh()
        await store.refresh()
        #expect(store.listError == "devicectl failed")
        #expect(log.lines.count == 1)
    }

    @Test func 手動リフレッシュはisManualRefreshingが立ち_自動ポーリングでは立たない() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        #expect(!store.hasLoaded)
        #expect(!store.isManualRefreshing)

        // refresh (自動ポーリング相当)
        await store.refresh()
        #expect(store.hasLoaded)
        #expect(!store.isManualRefreshing)

        // manualRefresh (手動更新)
        await store.manualRefresh()
        #expect(store.hasLoaded)
        #expect(!store.isManualRefreshing)
    }

    @Test func ログは_上限を超えたら古いものから捨てる() {
        let log = AppLog(limit: 3)
        for i in 0..<5 { log.append(.note, "\(i)") }
        #expect(log.lines.map(\.text) == ["2", "3", "4"])
    }

    @Test func 保存名の日時は_保存した時刻ではなく_撮影した時刻() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        let shotTime = Date(timeIntervalSince1970: 1_000_000)
        detail.screenshotDirectory = scratchDirectory()
        detail.now = { shotTime }
        await detail.takeScreenshot()
        #expect(detail.screenshotDate == shotTime)
        // 撮影のあと、時計が進んでも(保存の操作を後でしても)、既定の名前は変わらない
        detail.now = { shotTime.addingTimeInterval(3600) }
        #expect(detail.suggestedScreenshotName == screenshotFileName(deviceName: "Duo", capturedAt: shotTime))
        #expect(detail.suggestedScreenshotName != screenshotFileName(deviceName: "Duo", capturedAt: shotTime.addingTimeInterval(3600)))
    }

    @Test func 撮影の前は_既定の名前が無い() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(detail.suggestedScreenshotName == nil)
    }

    @Test func 保存名の形式() {
        let date = Date(timeIntervalSince1970: 1_793_428_256)  // 2026-10-31 06:30:56 UTC
        let utc = TimeZone(identifier: "UTC")!
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        #expect(screenshotFileName(deviceName: "iPhone Duo", capturedAt: date, timeZone: utc) == "Screenshot iPhone Duo 2026-10-31 at 06.30.56.png")
        #expect(screenshotFileName(deviceName: "iPhone Duo", capturedAt: date, timeZone: jst) == "Screenshot iPhone Duo 2026-10-31 at 15.30.56.png")
        #expect(screenshotFileName(deviceName: "A/B: C", capturedAt: date, timeZone: utc) == "Screenshot A-B- C 2026-10-31 at 06.30.56.png")
    }

    @Test func 選び直したあとに_前のデバイスの接続が終わっても_購読は始まらない() async throws {
        let backend = SlowBackend()
        let store = DeviceStore(backend: backend, log: AppLog())
        await store.refresh()
        store.selectedID = "id-A"          // A の open が止まったまま
        try await Task.sleep(for: .milliseconds(50))
        store.selectedID = "id-B"          // B に切り替える(A は破棄される)
        try await Task.sleep(for: .milliseconds(100))
        backend.release()                  // 今になって A の open が終わる
        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.sessionA.calls.isEmpty, "選択を外した A に、何かが送られている: \(backend.sessionA.calls)")
        #expect(store.detail?.entry.name == "B")
        #expect(await eventually { store.detail?.phase == .ready })
    }

    @Test func 撮り直すと_前の画像のファイルは消える() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        let directory = scratchDirectory()
        detail.screenshotDirectory = directory
        await detail.takeScreenshot()
        let first = detail.screenshot?.path
        #expect(files(in: directory).count == 1)
        await detail.takeScreenshot()
        #expect(files(in: directory).count == 1)
        #expect(detail.screenshot?.path != first)
        #expect(first.map { !FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test func 別のデバイスに切り替えると_画像のファイルは消える() async throws {
        let backend = FakeBackend(devices: [entry("Duo"), entry("SE")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        let directory = scratchDirectory()
        detail.screenshotDirectory = directory
        await detail.takeScreenshot()
        #expect(files(in: directory).count == 1)
        store.selectedID = "id-SE"
        #expect(files(in: directory).isEmpty)
        #expect(detail.screenshot == nil)
    }

    @Test func 解放されると_画像のファイルは消える() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let directory = scratchDirectory()
        do {
            let detail = DeviceDetailStore(entry: entry("Duo"), backend: backend, log: AppLog())
            detail.screenshotDirectory = directory
            await detail.connect()
            await detail.takeScreenshot()
            #expect(files(in: directory).count == 1)
        }
        #expect(files(in: directory).isEmpty)
    }

    @Test func 撮影に失敗したら_書きかけのファイルは残らない() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        backend.session.screenshotError = CLIError("Failed to take a screenshot")
        let (store, log) = makeStore(backend)
        let detail = await select(store, "Duo")
        let directory = scratchDirectory()
        detail.screenshotDirectory = directory
        await detail.takeScreenshot()
        #expect(files(in: directory).isEmpty)
        #expect(detail.screenshot == nil)
        #expect(log.lines.last?.text == "Taking screenshot failed: Failed to take a screenshot")
    }

    @Test func 購読が切れたら_開き直せて_開き直すと値が戻る() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(await eventually { backend.session.calls.contains("readings") })
        backend.session.emit(angle: 90)
        #expect(await eventually { detail.reading?.mechanicalAngle == 90 })
        #expect(!detail.needsReconnect)

        backend.session.endStream()
        #expect(await eventually { detail.streamError != nil })
        #expect(detail.needsReconnect)

        await detail.connect()
        #expect(detail.reading == nil, "開き直しの直後に、古い値が残っている")
        #expect(detail.streamError == nil)
        #expect(!detail.needsReconnect)
        #expect(await eventually { backend.session.calls.filter { $0 == "readings" }.count == 2 })
        backend.session.emit(angle: 120)
        #expect(await eventually { detail.reading?.mechanicalAngle == 120 })
    }

    @Test func エラーで購読が切れても_開き直せる() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(await eventually { backend.session.calls.contains("readings") })
        backend.session.failStream(CLIError("The hinge angle stream failed: link lost"))
        #expect(await eventually { detail.streamError == "The hinge angle stream failed: link lost" })
        #expect(detail.needsReconnect)
    }

    @Test func 対応の問い合わせが失敗したままなら_開き直すと確かめ直す() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        backend.session.supportResult = .unknown("timed out")
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        #expect(!detail.canUseHinge)
        #expect(detail.needsReconnect)

        backend.session.supportResult = .supported
        await detail.connect()
        #expect(detail.canUseHinge)
        #expect(!detail.needsReconnect)
        #expect(await eventually { backend.session.calls.contains("readings") })
    }

    @Test func 非対応のデバイスや_正常な接続では_開き直しの案内は出ない() async throws {
        let backend = FakeBackend(devices: [entry("SE")])
        backend.session.supportResult = .unsupported
        let (store, _) = makeStore(backend)
        let detail = await select(store, "SE")
        #expect(!detail.needsReconnect)
    }

    @Test func 開き直しても_撮った画像は消えない() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        let directory = scratchDirectory()
        detail.screenshotDirectory = directory
        await detail.takeScreenshot()
        await detail.connect()
        #expect(detail.screenshot != nil)
        #expect(files(in: directory).count == 1)
    }

    @Test func 切断中の状態に戻っていたら_開き直しで起こす() async throws {
        let backend = FakeBackend(devices: [entry("Duo")])
        let (store, _) = makeStore(backend)
        let detail = await select(store, "Duo")
        // 一覧の更新で、切断中に変わった(トンネルのアイドル)
        detail.update(entry: entry("Duo", state: .disconnected))
        backend.wakeResult = [entry("Duo", state: .connected)]
        await detail.connect()
        #expect(backend.wakeCalls == 1)
        #expect(detail.phase == .ready)
        #expect(detail.entry.isConnected)
    }
}
