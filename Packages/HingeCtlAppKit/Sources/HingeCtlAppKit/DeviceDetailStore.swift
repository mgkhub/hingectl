import Foundation
import HingeCtlCore
import Observation

/// 選んだ 1 台のデバイスの状態と操作。ヒンジ角は購読で常時更新する(購読は、接続を保つ役も兼ねる見込み)。
@MainActor @Observable
public final class DeviceDetailStore {
    public enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    public private(set) var entry: DeviceEntry
    public private(set) var phase: Phase = .idle
    public private(set) var support: HingeSupport = .unsupported
    public private(set) var reading: HingeReading?
    public private(set) var streamError: String?
    public private(set) var orientation: OrientationName?
    public private(set) var posture: PostureSnapshot?
    public private(set) var screenshot: ScreenshotOutput?
    /// `screenshot` を撮った時刻(保存の操作をした時刻ではない)
    public private(set) var screenshotDate: Date?
    /// 実行中の操作の名前。nil なら、操作できる。
    public private(set) var busyLabel: String?
    public private(set) var isDragging = false
    public private(set) var isSweeping = false
    /// 確認の待ち秒数(CLI の `-t`)。0 なら、確認せずに送る。
    public var timeout: Double = 2

    /// 撮った画像を置くフォルダ(既定は一時フォルダ。テストで差し替える)。ここに置いたファイルは、
    /// 次の撮影・別のデバイスへの切り替え・終了のときに消す(保存は、別のコピーとして行う)。
    public var screenshotDirectory = FileManager.default.temporaryDirectory

    /// 現在時刻。撮影の時刻の記録に使う(テストで差し替える)。
    public var now: @Sendable () -> Date = { Date() }

    /// ドラッグ中に送る間隔の下限。約 60Hz(`sweep` の実測で、連続送信は問題なし)。
    public var minSendInterval: Duration = .milliseconds(16)

    private let backend: any HingeBackend
    private let log: AppLog
    /// `disconnect()` のたびに進める。途中の `connect()` が、`await` から戻ったときに、自分の世代が古ければ、何もせずに終わる
    /// (選び直されたあとに接続が終わって、持ち主のいない購読が残るのを防ぐ)。
    private var generation = 0
    private var session: (any HingeSession)?
    private var streamTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    private var sender: (any AngleSender)?
    private var pumpTask: Task<Void, Never>?
    private var pendingAngle: Double?
    private var sentSinceFlush = false
    private var lastSent: ContinuousClock.Instant?

    public init(entry: DeviceEntry, backend: any HingeBackend, log: AppLog) {
        self.entry = entry
        self.backend = backend
        self.log = log
    }

    public var isBusy: Bool { busyLabel != nil }
    public var isReady: Bool { phase == .ready }
    /// ヒンジを使う操作ができるか(CLI と同じく、`supported` のときだけ)
    public var canUseHinge: Bool { isReady && support == .supported }

    /// ヒンジを使えない理由。使えるときは nil。
    public var hingeUnavailableReason: String? {
        guard isReady else { return nil }
        switch support {
        case .supported: return nil
        case .unsupported: return "\(entry.name) does not support the hinge."
        case .unknown(let reason): return "Cannot determine whether \(entry.name) supports the hinge: \(reason)"
        }
    }

    /// 開き直す(`connect()`)ことで、復帰できる状態か。ヒンジ角の購読が切れた(切断・スリープなど)、
    /// または、対応の問い合わせが失敗した(`unknown`)ままだと、選び直すまで操作が戻らない。
    public var needsReconnect: Bool {
        guard isReady else { return false }
        if streamError != nil { return true }
        if case .unknown = support { return true }
        return false
    }

    /// 一覧の更新を反映する(接続状態の変化など)。別のデバイスのものは無視する。
    public func update(entry newEntry: DeviceEntry) {
        guard newEntry.id == entry.id else { return }
        entry = newEntry
    }

    // MARK: 接続

    /// 開く(開き直しにも使う)。切断中のデバイスは、先に起こす。
    public func connect() async {
        guard phase != .connecting else { return }
        stopSessions()
        let mine = generation
        phase = .connecting
        do {
            var target = entry
            if !entry.isConnected {
                guard entry.isWakeable else {
                    throw CLIError("\(entry.name) is not reachable (state: \(entry.connectionState.text))")
                }
                let woken = await backend.wake([entry]).first
                guard mine == generation else { return }
                guard let woken else { throw CLIError("Could not connect to \(entry.name)") }
                target = woken
                entry = woken
            }
            let opened = try await backend.open(target)
            guard mine == generation else { return }
            let supported = await opened.support()
            guard mine == generation else { return }
            session = opened
            support = supported
            phase = .ready
            if support == .supported { startStreaming(opened) }
            await readPosture()
        } catch {
            guard mine == generation else { return }
            phase = .failed(Self.message(error))
            log.append(.error, "Cannot connect: \(Self.message(error))")
        }
    }

    /// 購読と実行中の送信を止める(別のデバイスを選んだとき、画面を閉じるとき)。
    public func disconnect() {
        stopSessions()
        discardScreenshot()
    }

    /// 開き直しのときも使う。撮った画像は、開き直しでは消さない。
    private func stopSessions() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        sweepTask?.cancel()
        sweepTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        pendingAngle = nil
        sender = nil
        sentSinceFlush = false
        isDragging = false
        isSweeping = false
        busyLabel = nil
        session = nil
        reading = nil
        streamError = nil
    }

    private func startStreaming(_ session: any HingeSession) {
        streamTask = Task { [weak self] in
            do {
                for try await batch in try await session.readings() {
                    guard let self else { return }
                    guard let last = batch.last else { continue }
                    self.reading = last
                    self.streamError = nil
                }
                self?.streamError = "The hinge angle stream ended"
            } catch is CancellationError {
            } catch {
                self?.streamError = Self.message(error)
            }
        }
    }

    // MARK: ヒンジ角

    /// 角度を送り、到達を確認する(プリセット・数値入力用。CLI の `set`)。
    public func setAngle(_ degrees: Double) async {
        let _: Void? = await perform("Setting angle", requiresHinge: true, validating: validateAngle(degrees)) { session, timeout in
            try await session.setAngle(degrees, timeout: timeout)
        }
    }

    /// スライダーのドラッグ中の値を送る。間隔を約 60Hz に間引き、最後の値は残す。
    public func dragAngle(_ degrees: Double) {
        guard canUseHinge, !isBusy, HingeLimits.angle.contains(degrees) else { return }
        isDragging = true
        pendingAngle = degrees
        startPump()
    }

    /// ドラッグの終わり。最後の値を送り、送信を流し切る。
    public func endDrag(_ degrees: Double) {
        guard isDragging else { return }
        isDragging = false
        if HingeLimits.angle.contains(degrees) { pendingAngle = degrees }
        startPump()
    }

    private func startPump() {
        guard pumpTask == nil, let session else { return }
        pumpTask = Task { [weak self] in
            await self?.pump(session)
            self?.pumpTask = nil
        }
    }

    private func pump(_ session: any HingeSession) async {
        do {
            if sender == nil { sender = try await session.beginSending() }
            let clock = ContinuousClock()
            while pendingAngle != nil {
                if let lastSent, clock.now - lastSent < minSendInterval {
                    try await clock.sleep(for: minSendInterval - (clock.now - lastSent))
                }
                guard let value = pendingAngle, let sender else { break }
                pendingAngle = nil
                try sender.send(value)
                lastSent = clock.now
                sentSinceFlush = true
            }
            // 待ちの間に、ドラッグが終わっているかもしれない。ここから先に `await` は無い。
            if !isDragging, sentSinceFlush {
                sender?.flush()
                sentSinceFlush = false
            }
        } catch is CancellationError {
        } catch {
            pendingAngle = nil
            isDragging = false
            fail("Sending the angle", error)
        }
    }

    public func sweep(from: Double, to: Double, seconds: Double) {
        guard !isBusy else { return }
        if let problem = validateAngle(from) ?? validateAngle(to) ?? validateSeconds(seconds) {
            log.append(.error, problem)
            return
        }
        isSweeping = true
        sweepTask = Task { [weak self] in
            _ = await self?.perform("Sweeping", requiresHinge: true) { session, timeout in
                try await session.sweep(from: from, to: to, seconds: seconds, timeout: timeout)
            }
            self?.isSweeping = false
            self?.sweepTask = nil
        }
    }

    public func cancelSweep() { sweepTask?.cancel() }

    // MARK: 向き

    public func setOrientation(_ name: OrientationName) async {
        let done: Void? = await perform("Setting orientation", requiresHinge: false) { session, timeout in
            try await session.setOrientation(name, timeout: timeout)
        }
        if done != nil { orientation = name }
    }

    public func rotate(_ direction: RotationDirection) async {
        let result = await perform("Rotating", requiresHinge: false) { session, timeout in
            try await session.rotate(direction, timeout: timeout)
        }
        if let result { orientation = result }
    }

    // MARK: posture・スクリーンショット

    /// 角度・向き・ディスプレイを読み直す(画面の更新ボタン)。
    public func refreshPosture() async {
        let _: Void? = await perform("Reading posture", requiresHinge: false, verifying: false) { [weak self] _, _ in
            await self?.readPosture()
        }
    }

    /// 角度・向き・ディスプレイを読む。ヒンジ非対応のデバイスでも、読めた項目だけを表示する(CLI の `posture` と同じ)。
    private func readPosture() async {
        guard let session else { return }
        do {
            let snapshot = try await session.posture()
            posture = snapshot
            if case .known(let name) = snapshot.orientation { orientation = name }
        } catch {
            fail("Reading posture", error)
        }
    }

    /// UI を載せているディスプレイの PNG を撮る。前の画像のファイルは、撮り直しの成否にかかわらず、先に消す。
    public func takeScreenshot() async {
        discardScreenshot()
        let path = screenshotDirectory.appendingPathComponent("hingectl-\(UUID().uuidString).png").path
        let clock = now
        let taken = await perform("Taking screenshot", requiresHinge: false, verifying: false) { session, _ in
            let shot = try await session.screenshot(to: path)
            return (shot, clock())
        }
        if let (shot, date) = taken {
            screenshot = shot
            screenshotDate = date
        } else {
            // 失敗したときに、書きかけのファイルが残らないようにする
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// 撮った画像のファイルを消して、表示も消す。
    public func discardScreenshot() {
        if let shot = screenshot { try? FileManager.default.removeItem(atPath: shot.path) }
        screenshot = nil
        screenshotDate = nil
    }

    /// 撮った画像を保存するときの、ファイル名の既定値(撮影の時刻を使う)
    public var suggestedScreenshotName: String? {
        screenshotDate.map { screenshotFileName(deviceName: entry.name, capturedAt: $0) }
    }

    // MARK: 共通

    /// 操作を 1 つずつ実行する(実行中や、ドラッグ中は何もしない)。成功したら値を返し、失敗はログ欄に出して nil を返す。
    /// `requiresHinge` の操作は、ヒンジに対応していないデバイスでは、何も送らない(CLI の `requiresHinge` と同じ分け方。向きは、ヒンジが無くても使える)。
    /// `verifying` が true の操作(角度・向きを変えるもの)は、終わったあとに posture を読み直す。
    private func perform<T>(_ label: String, requiresHinge: Bool, verifying: Bool = true, validating problem: String? = nil,
                            _ body: (any HingeSession, Double) async throws -> T) async -> T? {
        guard let session, !isBusy, !isDragging else { return nil }
        if requiresHinge && !canUseHinge { return nil }
        if let problem { log.append(.error, problem); return nil }
        guard HingeLimits.timeout.contains(timeout) else {
            log.append(.error, "Timeout must be a number from 0 to 3600: \(String(format: "%g", timeout))")
            return nil
        }
        busyLabel = label
        defer { busyLabel = nil }
        let result: T
        do {
            result = try await body(session, timeout)
        } catch is CancellationError {
            return nil
        } catch {
            fail(label, error)
            return nil
        }
        if verifying {
            await readPosture()
            if let angle = posture?.mechanicalAngle {
                let current = reading
                let sensor = posture?.sensorAngle ?? angle
                if current == nil || abs(current!.mechanicalAngle - angle) > 0.05 || abs(current!.sensorAngle - sensor) > 0.05 {
                    reading = HingeReading(
                        mechanicalAngle: angle,
                        sensorAngle: sensor,
                        isValid: current?.isValid ?? true,
                        minAngle: current?.minAngle ?? 0,
                        maxAngle: current?.maxAngle ?? 180,
                        timestamp: current?.timestamp ?? Date().timeIntervalSinceReferenceDate
                    )
                }
            }
        }
        return result
    }

    private func fail(_ label: String, _ error: Error) {
        log.append(.error, "\(label) failed: \(Self.message(error))")
    }

    private func validateAngle(_ degrees: Double) -> String? {
        HingeLimits.angle.contains(degrees) ? nil : "Angle must be a number from 0 to 180: \(String(format: "%g", degrees))"
    }

    private func validateSeconds(_ seconds: Double) -> String? {
        HingeLimits.sweepSeconds.contains(seconds) ? nil : "Duration must be a number from 0 to 3600: \(String(format: "%g", seconds))"
    }

    isolated deinit {
        if let shot = screenshot {
            try? FileManager.default.removeItem(atPath: shot.path)
        }
        streamTask?.cancel()
        sweepTask?.cancel()
        pumpTask?.cancel()
    }

    static func message(_ error: Error) -> String {
        (error as? CLIError)?.description ?? (error as NSError).localizedDescription
    }
}
